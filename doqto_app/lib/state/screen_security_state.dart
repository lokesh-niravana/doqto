import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/router/app_router.dart';
import '../core/tokens/colors.dart';
import '../core/tokens/radii.dart';
import '../core/tokens/spacing.dart';
import '../core/tokens/typography.dart';
import '../data/models/conversation.dart';
import '../data/services/screen_security.dart';
import 'chat_state.dart';
import 'notification_state.dart';
import 'org_state.dart';

final screenshotDetectorProvider =
    Provider<ScreenshotDetector>((ref) => ChannelScreenshotDetector());

final screenSecurityProvider =
    Provider<ScreenSecurity>((ref) => const ChannelScreenSecurity());

/// Whether this platform runs Android — overridable so tests can exercise
/// the FLAG_SECURE rule on a Mac.
final isAndroidProvider =
    Provider<bool>((ref) => !kIsWeb && Platform.isAndroid);

/// Copy for the screenshot toast (English; the toast has no BuildContext
/// with a locale when it fires from a platform callback).
const screenshotToastText = 'Screenshots of this chat are recorded';

/// iOS: a screenshot taken while a chat is open is audited server-side
/// (`POST /audit/screenshot`) and announced with a toast. Watched once from
/// the root (settings_services.dart).
final screenshotAuditProvider = Provider<void>((ref) {
  final sub = ref.watch(screenshotDetectorProvider).taken.listen((_) {
    final convId = ref.read(activeConversationProvider);
    if (convId == null) return;
    unawaited(
      ref.read(settingsRepositoryProvider).auditScreenshot(convId).catchError((_) {}),
    );
    showScreenshotToast();
  });
  ref.onDispose(sub.cancel);
});

/// A toast over whatever is on screen, through the root navigator's overlay
/// (there is no app-wide ScaffoldMessenger key). No-op without an overlay.
void showScreenshotToast({Duration duration = const Duration(seconds: 3)}) {
  final overlay = rootNavigatorKey.currentState?.overlay;
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      left: AppSpacing.lg,
      right: AppSpacing.lg,
      bottom: MediaQuery.paddingOf(context).bottom + 96,
      child: IgnorePointer(
        child: Material(
          key: const ValueKey('screenshot-toast'),
          color: AppColors.gray800,
          borderRadius: AppRadii.rLg,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                const Icon(Icons.screenshot_monitor_rounded, color: AppColors.white, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    screenshotToastText,
                    style: AppText.bodyPrimary.copyWith(color: AppColors.gray50),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Timer(duration, () {
    if (entry.mounted) entry.remove();
  });
}

/// The FLAG_SECURE rule: Android, an org conversation is open, and that org
/// blocks screenshots. Pure so it is unit-testable.
bool shouldSecureScreen({
  required bool isAndroid,
  required Conversation? open,
  required OrgState org,
}) {
  if (!isAndroid || open == null) return false;
  final orgId = open.orgId;
  if (orgId == null) return false;
  final current = org.current;
  if (current == null || current.id != orgId) return false;
  return current.policies.blockScreenshots;
}

/// Android: sets / clears FLAG_SECURE as org chats with `block_screenshots`
/// open and close. Watched once from the root.
final flagSecureProvider = Provider<void>((ref) {
  final isAndroid = ref.watch(isAndroidProvider);
  if (!isAndroid) return;
  final convId = ref.watch(activeConversationProvider);
  final convs = ref.watch(conversationsProvider).asData?.value ?? const <Conversation>[];
  final open = convId == null ? null : convs.where((c) => c.id == convId).firstOrNull;
  final secure = shouldSecureScreen(
    isAndroid: isAndroid,
    open: open,
    org: ref.watch(orgProvider),
  );
  unawaited(ref.read(screenSecurityProvider).setSecure(secure));
});
