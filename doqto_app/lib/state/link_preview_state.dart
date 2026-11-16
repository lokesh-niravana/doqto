import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../data/models/message.dart';
import 'privacy_state.dart';

/// One server-side link preview per URL (batch 4), kept for the session so a
/// URL quoted in ten bubbles is fetched once. Null when the server declined
/// (not HTML, unreachable, previews off) — the card simply does not show.
final linkPreviewProvider = FutureProvider.family<LinkPreview?, String>((ref, url) async {
  ref.keepAlive();
  try {
    final p = await ref.read(chatRepositoryProvider).linkPreview(url);
    return p.isEmpty ? null : p;
  } catch (_) {
    return null;
  }
});

/// Whether this user wants previews at all (privacy → link previews).
final linkPreviewsEnabledProvider = Provider<bool>((ref) {
  final privacy = ref.watch(privacyProvider).asData?.value;
  return privacy?.linkPreviews ?? true;
});
