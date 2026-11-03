import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where cached chat media physically lives. Split out so tests can run the
/// [ChatMediaCache] logic against a temp directory instead of sqflite +
/// path_provider.
abstract class MediaCacheBackend {
  /// The cached file for [key], or null when it was never stored, expired,
  /// or the OS purged it.
  Future<File?> get(String key);

  /// Download [url] and store it under [key].
  Future<File> download(String url, String key);

  /// Store bytes we already hold (the sender's own upload) under [key].
  Future<File> put(String key, Uint8List bytes, String extension);

  Future<void> remove(String key);

  Future<void> clear();
}

/// Chat images, downloaded once and then served from the phone.
///
/// Why this exists: the server hands out a fresh presigned URL (5 min TTL)
/// every time a bubble asks, and a URL-keyed cache never hits on a URL it has
/// not seen — so every image re-downloaded on every visit. Here the key is the
/// message id, which never changes, and a URL is only requested on a miss.
///
/// Safeguards (HIPAA §164.312 device safeguards; see docs/security.md):
///   * app-private cache dir, excluded from iCloud / Android Auto Backup;
///   * iOS NSFileProtectionComplete on the dir and every file, so cached
///     images are unreadable while the phone is locked;
///   * evicted after [stalePeriod] unused or past [maxObjects];
///   * [clear] on sign-out, session end and account deletion;
///   * [evict] when a message is deleted or hidden.
class ChatMediaCache {
  ChatMediaCache(this._backend);

  static const cacheKey = 'doqto_chat_media';
  static const stalePeriod = Duration(days: 30);
  static const maxObjects = 500;

  final MediaCacheBackend _backend;

  /// One download per message, however many bubbles ask at once (the thread
  /// bubble and the full-screen viewer, or a rebuild mid-download).
  final Map<String, Future<File>> _inFlight = {};

  /// Files already resolved this run — lets a bubble paint synchronously when
  /// it remounts (leaving and re-entering a chat) instead of flashing a
  /// spinner while the cache index is consulted.
  final Map<String, File> _resolved = {};

  static String _key(String messageId) => 'msg:$messageId';

  /// Synchronous hit from this run, or null.
  File? peek(String messageId) {
    final f = _resolved[messageId];
    if (f == null) return null;
    if (!f.existsSync()) {
      _resolved.remove(messageId);
      return null;
    }
    return f;
  }

  /// The image for [messageId]: from the phone when cached, otherwise one
  /// download via a freshly resolved URL.
  Future<File> image(String messageId, Future<String> Function() resolveUrl) {
    final hit = peek(messageId);
    if (hit != null) return Future.value(hit);
    // Block body on purpose: `=> _inFlight.remove(id)` would return this very
    // future to whenComplete, which then waits on itself forever.
    return _inFlight[messageId] ??=
        _load(messageId, resolveUrl).whenComplete(() {
      _inFlight.remove(messageId);
    });
  }

  Future<File> _load(
      String messageId, Future<String> Function() resolveUrl) async {
    final key = _key(messageId);
    final cached = await _backend.get(key);
    if (cached != null) return _resolved[messageId] = cached;
    final url = await resolveUrl();
    return _resolved[messageId] = await _backend.download(url, key);
  }

  /// The sender already has the bytes: store them under the server id so the
  /// bubble never downloads its own upload.
  Future<void> seed(String messageId, File source) async {
    try {
      final bytes = await source.readAsBytes();
      final ext = p.extension(source.path).replaceFirst('.', '');
      _resolved[messageId] = await _backend.put(
          _key(messageId), bytes, ext.isEmpty ? 'img' : ext);
    } catch (_) {
      // Best effort: a miss just means one download later.
    }
  }

  Future<void> evict(String messageId) async {
    _resolved.remove(messageId);
    try {
      await _backend.remove(_key(messageId));
    } catch (_) {}
  }

  Future<void> clear() async {
    _resolved.clear();
    _inFlight.clear();
    await _backend.clear();
  }
}

/// Production backend: flutter_cache_manager under the OS cache dir, with iOS
/// complete file protection applied to the directory and each stored file.
class CacheManagerMediaBackend implements MediaCacheBackend {
  CacheManagerMediaBackend();

  // One manager per cache key for the whole process: flutter_cache_manager
  // keeps an index per instance, and two instances over one folder disagree.
  static final CacheManager _manager = CacheManager(Config(
    ChatMediaCache.cacheKey,
    stalePeriod: ChatMediaCache.stalePeriod,
    maxNrOfCacheObjects: ChatMediaCache.maxObjects,
  ));

  late final Future<Directory> _dir = _protectDir();

  Future<Directory> _protectDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, ChatMediaCache.cacheKey));
    await dir.create(recursive: true);
    await FileProtection.complete(dir.path);
    return dir;
  }

  Future<File> _protect(File f) async {
    await FileProtection.complete(f.path);
    return f;
  }

  @override
  Future<File?> get(String key) async {
    await _dir;
    return (await _manager.getFileFromCache(key))?.file;
  }

  @override
  Future<File> download(String url, String key) async {
    await _dir;
    final info = await _manager.downloadFile(url, key: key);
    return _protect(info.file);
  }

  @override
  Future<File> put(String key, Uint8List bytes, String extension) async {
    await _dir;
    // The url argument is only metadata here; it must not be a real link.
    final f = await _manager.putFile('local://$key', bytes,
        key: key,
        maxAge: ChatMediaCache.stalePeriod,
        fileExtension: extension);
    return _protect(f);
  }

  @override
  Future<void> remove(String key) => _manager.removeFile(key);

  @override
  Future<void> clear() async {
    await _manager.emptyCache();
    // A wipe must not depend on the index being right: delete whatever is
    // left in the folder too.
    final dir = await _dir;
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
    // Builds up to 41 cached chat photos by presigned URL in the shared
    // default cache, which nothing ever wiped. Avatars live there too and
    // simply re-download.
    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {}
  }
}

/// iOS Data Protection for paths the Dart side writes. Android needs nothing:
/// app-private storage sits in credential-encrypted storage on Android 10+.
class FileProtection {
  static const _channel = MethodChannel('doqto/file_protection');

  /// NSFileProtectionComplete: readable only while the device is unlocked.
  /// A directory passes the class on to files created inside it.
  static Future<void> complete(String path) async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('complete', {'path': path});
    } on MissingPluginException {
      // Widget tests and older native builds: nothing to apply.
    } on PlatformException {
      // Never fail a chat render over a protection attribute.
    }
  }
}
