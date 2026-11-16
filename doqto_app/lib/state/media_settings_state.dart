import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../data/models/media_settings.dart';
import '../data/services/media_native.dart';

/// Storage and data (batch 5): upload quality and auto-download rules, kept
/// in the encrypted chat cache box.
class MediaSettingsNotifier extends Notifier<MediaSettings> {
  @override
  MediaSettings build() {
    try {
      return ref.read(chatCacheProvider).mediaSettings();
    } catch (_) {
      return MediaSettings.defaults;
    }
  }

  Future<void> setUploadQuality(UploadQuality q) => _save(state.copyWith(uploadQuality: q));

  Future<void> setRule(MediaDownloadKind kind, AutoDownloadRule rule) =>
      _save(state.withRule(kind, rule));

  Future<void> _save(MediaSettings next) async {
    state = next;
    try {
      await ref.read(chatCacheProvider).putMediaSettings(next);
    } catch (_) {}
  }
}

final mediaSettingsProvider =
    NotifierProvider<MediaSettingsNotifier, MediaSettings>(MediaSettingsNotifier.new);

/// The network the phone is on right now. Asked once per read; the thread
/// re-reads it when a bubble decides whether to download. Unknown → Wi-Fi.
final networkTypeProvider = FutureProvider.autoDispose<NetworkType>(
  (ref) => ref.watch(mediaNativeProvider).networkType(),
);

/// Does [kind] download without a tap on the current network? Works from a
/// provider ([Ref]) or a widget ([WidgetRef]) — both can `read`.
Future<bool> shouldAutoDownload(dynamic ref, MediaDownloadKind kind) async {
  final MediaSettings settings = ref.read(mediaSettingsProvider);
  final rule = settings.ruleFor(kind);
  if (rule == AutoDownloadRule.never) return false;
  if (rule == AutoDownloadRule.always) return true;
  try {
    final MediaNative native = ref.read(mediaNativeProvider);
    return rule.allowsOn(await native.networkType());
  } catch (_) {
    return true;
  }
}

/// Per-clientId upload progress (0.0–1.0) for bubbles still sending.
class UploadProgressNotifier extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => const {};

  void set(String clientId, double value) => state = {...state, clientId: value.clamp(0.0, 1.0)};

  void clear(String clientId) {
    if (!state.containsKey(clientId)) return;
    state = {...state}..remove(clientId);
  }
}

final uploadProgressProvider =
    NotifierProvider<UploadProgressNotifier, Map<String, double>>(UploadProgressNotifier.new);
