import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../data/models/network_profile.dart';

/// My privacy settings (batch 2). Every change is optimistic: the row flips at
/// once, the server is told with a one-field PATCH, and the row flips back if
/// that fails — the same shape as `react()` in chat_state.
class PrivacyNotifier extends AsyncNotifier<PrivacySettings> {
  @override
  Future<PrivacySettings> build() =>
      ref.read(networkRepositoryProvider).getPrivacy();

  /// [apply] produces the optimistic value; [patch] is what the server gets.
  Future<void> change({
    required PrivacySettings Function(PrivacySettings current) apply,
    required Map<String, dynamic> patch,
  }) async {
    final current = state.valueOrNull ?? PrivacySettings.defaults;
    state = AsyncData(apply(current));
    try {
      final confirmed =
          await ref.read(networkRepositoryProvider).patchPrivacy(patch);
      state = AsyncData(confirmed);
    } catch (e) {
      state = AsyncData(current);
      rethrow;
    }
  }
}

final privacyProvider =
    AsyncNotifierProvider<PrivacyNotifier, PrivacySettings>(PrivacyNotifier.new);
