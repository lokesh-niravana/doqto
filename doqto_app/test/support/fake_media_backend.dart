import 'dart:io';
import 'dart:typed_data';

import 'package:doqto_app/data/services/chat_media_cache.dart';

/// [MediaCacheBackend] over a temp directory: real files, no sqflite or
/// path_provider. Counts network downloads so tests can assert "once".
class FakeMediaBackend implements MediaCacheBackend {
  FakeMediaBackend() : dir = Directory.systemTemp.createTempSync('media_');

  final Directory dir;
  final Map<String, File> files = {};
  final List<String> downloadedUrls = [];
  int clears = 0;

  /// The bytes a "download" writes: a valid 1x1 PNG so Image.file decodes.
  static final Uint8List png = Uint8List.fromList(const [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
    0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ]);

  String _safe(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');

  @override
  Future<File?> get(String key) async {
    final f = files[key];
    return (f != null && f.existsSync()) ? f : null;
  }

  @override
  Future<File> download(String url, String key) async {
    downloadedUrls.add(url);
    final f = File('${dir.path}/${_safe(key)}.png')..writeAsBytesSync(png);
    return files[key] = f;
  }

  @override
  Future<File> put(String key, Uint8List bytes, String extension) async {
    final f = File('${dir.path}/${_safe(key)}.$extension')
      ..writeAsBytesSync(bytes);
    return files[key] = f;
  }

  @override
  Future<void> remove(String key) async {
    files.remove(key)?.deleteSync();
  }

  @override
  Future<void> clear() async {
    clears++;
    for (final f in files.values) {
      if (f.existsSync()) f.deleteSync();
    }
    files.clear();
  }
}
