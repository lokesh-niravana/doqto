import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'chat_media_cache.dart';

/// Downloads [url] into [target]. Split out so tests need no network.
typedef FileDownloader = Future<void> Function(String url, File target);

/// Chat documents, downloaded once and kept under their real file name.
///
/// Separate from [ChatMediaCache] because a viewer needs the name: QuickLook
/// and Android apps choose how to render from the extension, and the photo
/// cache names files after a guessed content type. Same safeguards otherwise
/// (see docs/security.md): app-private cache dir, iOS complete file
/// protection, keyed by message id, dropped after [staleAfter] unused, wiped
/// with the session, evicted when the message is deleted or hidden.
class ChatDocumentStore {
  ChatDocumentStore({
    Future<Directory> Function()? root,
    FileDownloader? download,
  }) : _rootResolver = root ?? _defaultRoot,
       _download = download ?? _httpDownload;

  static const folder = 'doqto_chat_docs';
  static const staleAfter = Duration(days: 30);
  static const _partial = '.part';

  final Future<Directory> Function() _rootResolver;
  final FileDownloader _download;

  late final Future<Directory> _root = _rootResolver();

  /// One download per message, however many taps land while it runs.
  final Map<String, Future<File>> _inFlight = {};
  bool _swept = false;

  static Future<Directory> _defaultRoot() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, folder));
    await dir.create(recursive: true);
    await FileProtection.complete(dir.path);
    return dir;
  }

  static Future<void> _httpDownload(String url, File target) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('download failed: ${response.statusCode}');
      }
      await response.pipe(target.openWrite());
    } finally {
      client.close();
    }
  }

  /// The sender chose the name, so it is untrusted: it must stay a single
  /// path segment inside this message's folder.
  static String safeName(String fileName) {
    final base = fileName.split(RegExp(r'[/\\]')).last;
    final clean = base.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_').trim();
    if (clean.isEmpty || clean == '.' || clean == '..') return 'document';
    if (clean.length <= 120) return clean;
    final ext = p.extension(clean);
    final keep = ext.length < 20 ? ext : '';
    return '${clean.substring(0, 120 - keep.length)}$keep';
  }

  Future<Directory> _messageDir(String messageId) async =>
      Directory(p.join((await _root).path, safeName(messageId)));

  Future<File?> _cached(Directory dir) async {
    if (!await dir.exists()) return null;
    await for (final e in dir.list()) {
      if (e is File && !e.path.endsWith(_partial)) return e;
    }
    return null;
  }

  /// The document for [messageId]: from the phone when stored, otherwise one
  /// download via a freshly resolved URL. Leaves nothing behind on failure.
  Future<File> open(
    String messageId,
    String fileName,
    Future<String> Function() resolveUrl,
  ) {
    // Block body on purpose: see ChatMediaCache.image.
    return _inFlight[messageId] ??= _load(messageId, fileName, resolveUrl)
        .whenComplete(() {
          _inFlight.remove(messageId);
        });
  }

  Future<File> _load(
    String messageId,
    String fileName,
    Future<String> Function() resolveUrl,
  ) async {
    if (!_swept) {
      _swept = true;
      unawaited(_sweep());
    }
    final dir = await _messageDir(messageId);
    final hit = await _cached(dir);
    if (hit != null) {
      // Opening counts as use: only unused documents go stale.
      await hit.setLastModified(DateTime.now());
      return hit;
    }
    final url = await resolveUrl();
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, safeName(fileName)));
    final partial = File('${target.path}$_partial');
    try {
      await _download(url, partial);
      await partial.rename(target.path);
    } catch (_) {
      await _deleteQuietly(dir);
      rethrow;
    }
    await FileProtection.complete(target.path);
    return target;
  }

  /// The sender already holds the bytes: file them under the server id so
  /// their own bubble opens without a download.
  Future<void> seed(String messageId, String fileName, File source) async {
    try {
      final dir = await _messageDir(messageId);
      await dir.create(recursive: true);
      final target = await source.copy(p.join(dir.path, safeName(fileName)));
      await FileProtection.complete(target.path);
    } catch (_) {
      // Best effort: a miss just means one download later.
    }
  }

  Future<void> evict(String messageId) async {
    try {
      await _deleteQuietly(await _messageDir(messageId));
    } catch (_) {}
  }

  Future<void> clear() async {
    _inFlight.clear();
    final root = await _root;
    if (!await root.exists()) return;
    await for (final e in root.list()) {
      await _deleteQuietly(e);
    }
  }

  Future<void> _sweep() async {
    try {
      final root = await _root;
      final cutoff = DateTime.now().subtract(staleAfter);
      await for (final e in root.list()) {
        if (e is! Directory) continue;
        final file = await _cached(e);
        if (file == null || (await file.lastModified()).isBefore(cutoff)) {
          await _deleteQuietly(e);
        }
      }
    } catch (_) {}
  }

  static Future<void> _deleteQuietly(FileSystemEntity e) async {
    try {
      await e.delete(recursive: true);
    } catch (_) {}
  }
}
