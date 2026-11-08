import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Own-photo wallpapers (batch 6). The picture never leaves the phone: it is
/// copied into `<documents>/wallpapers/<key>.jpg` (key = conversation id or
/// `default`), marked NSFileProtectionComplete on iOS, and the server only
/// ever stores the marker `local` in `prefs.wallpaper`.
class WallpaperStore {
  WallpaperStore(this.dir);
  final Directory dir;

  static const defaultKey = 'default';
  static const _protection = MethodChannel('doqto/file_protection');

  File fileFor(String key) => File('${dir.path}/$key.jpg');

  /// The photo for [key] if one was saved on this device.
  File? existing(String key) {
    final f = fileFor(key);
    return f.existsSync() ? f : null;
  }

  Future<File> save(String key, File source) async {
    await dir.create(recursive: true);
    final target = fileFor(key);
    await source.copy(target.path);
    try {
      await _protection.invokeMethod('complete', {'path': target.path});
    } catch (_) {} // Android / tests: no channel
    return target;
  }

  Future<void> remove(String key) async {
    final f = fileFor(key);
    if (await f.exists()) await f.delete();
  }

  Future<void> clear() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

final wallpaperStoreProvider = FutureProvider<WallpaperStore>((ref) async {
  final docs = await getApplicationDocumentsDirectory();
  return WallpaperStore(Directory('${docs.path}/wallpapers'));
});

/// The own photo a thread should show: this chat's, else the default one,
/// else null. Invalidate after saving / removing a photo.
final wallpaperPhotoProvider = Provider.family<File?, String>((ref, convId) {
  final store = ref.watch(wallpaperStoreProvider).asData?.value;
  if (store == null) return null;
  return store.existing(convId) ?? store.existing(WallpaperStore.defaultKey);
});
