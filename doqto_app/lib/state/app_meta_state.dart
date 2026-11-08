import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../data/models/app_meta.dart';

/// `ios` | `android` — overridable so tests can exercise either branch.
final platformNameProvider = Provider<String>(
  (ref) => (!kIsWeb && Platform.isAndroid) ? 'android' : 'ios',
);

/// Installed version in pubspec form ("1.0.0+45").
final appVersionProvider =
    FutureProvider<String>((ref) => ref.watch(deviceInfoProvider).appVersion());

/// `GET /app/min-version`; any failure (offline, 5xx) → null, which never
/// gates the app — a bad network must not lock people out.
final minVersionProvider = FutureProvider<MinVersion?>((ref) async {
  try {
    return await ref.watch(settingsRepositoryProvider).minVersion();
  } catch (_) {
    return null;
  }
});

/// True when this build is below the store minimum for its platform.
final forceUpdateProvider = Provider<bool>((ref) {
  final min = ref.watch(minVersionProvider).asData?.value;
  final version = ref.watch(appVersionProvider).asData?.value;
  if (min == null || version == null) return false;
  return min.requiresUpdate(
    installedVersion: version,
    platform: ref.watch(platformNameProvider),
  );
});

/// `GET /app/legal`, falling back to the compiled-in defaults.
final legalLinksProvider = FutureProvider<LegalLinks>((ref) async {
  try {
    return await ref.watch(settingsRepositoryProvider).legal();
  } catch (_) {
    return LegalLinks.defaults;
  }
});

/// Store page for this platform.
String storeUrl(String platform) => platform == 'android'
    ? 'https://play.google.com/store/apps/details?id=com.doqto.app'
    : 'https://apps.apple.com/app/id6823733882';
