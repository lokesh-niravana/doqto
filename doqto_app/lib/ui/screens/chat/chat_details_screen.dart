import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/conversation.dart';
import '../../../data/models/organization.dart';
import '../../../state/auth_state.dart';
import '../../../state/chat_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/fade_slide_in.dart';
import '_conversation_display.dart';

/// Timer options — mirror of DISAPPEAR_OPTIONS_SEC on the backend.
const Map<int?, String> kDisappearOptions = {
  null: 'Off',
  86400: '24 hours',
  604800: '7 days',
  2592000: '30 days',
  7776000: '90 days',
};

class ChatDetailsScreen extends ConsumerWidget {
  final String conversationId;
  const ChatDetailsScreen({super.key, required this.conversationId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authProvider).user;
    final convs =
        ref.watch(conversationsProvider).asData?.value ??
        const <Conversation>[];
    final conv = convs.where((c) => c.id == conversationId).firstOrNull;
    final currentOrg = ref.watch(orgProvider).current;
    final orgMembers = currentOrg == null
        ? const <OrgMember>[]
        : (ref.watch(orgMembersProvider(currentOrg.id)).asData?.value ??
              const <OrgMember>[]);

    if (conv == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Chat info')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final display = conversationDisplay(
      c: conv,
      orgMembers: orgMembers,
      meId: me?.id,
      fallbackColorIndex: 0,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Chat info')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        children: [
          // Header — avatar + name; direct chats tap through to the peer profile.
          FadeSlideIn.staggered(
            0,
            AppPressable(
              onTap: display.isDirect && display.otherUser != null
                  ? () => context.push(AppRoutes.person(display.otherUser!.id))
                  : null,
              child: Column(
                children: [
                  DoctorAvatar(
                    initials: display.initials,
                    size: AvatarSize.xxl,
                    imageUrl: display.otherUser?.avatarPresignedUrl,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    display.title,
                    style: AppText.display,
                    textAlign: TextAlign.center,
                  ),
                  if (display.otherUser?.specialty case final specialty?
                      when specialty.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(specialty, style: AppText.caption),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FadeSlideIn.staggered(
            1,
            _Section(
              title: 'Messages',
              child: AppPressable(
                key: const ValueKey('details-starred'),
                onTap: () => context.push(AppRoutes.starredIn(conv.id)),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.star_outline_rounded, color: AppColors.medBlue),
                  title: Text(Strings.chatStarredMessages, style: AppText.bodyPrimary),
                  trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                ),
              ),
            ),
          ),
          // Batch 6: per-chat colour theme, wallpaper and notifications.
          FadeSlideIn.staggered(
            2,
            _Section(
              title: 'Personalise',
              child: Column(
                children: [
                  ListTile(
                    key: const ValueKey('details-chat-theme'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.palette_outlined, color: AppColors.medBlue),
                    title: Text('Chat colour', style: AppText.bodyPrimary),
                    trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                    onTap: () => context.push(AppRoutes.chatThemeFor(conv.id)),
                  ),
                  ListTile(
                    key: const ValueKey('details-wallpaper'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.wallpaper_rounded, color: AppColors.medBlue),
                    title: Text('Wallpaper', style: AppText.bodyPrimary),
                    trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                    onTap: () => context.push(AppRoutes.wallpaperFor(conv.id)),
                  ),
                  ListTile(
                    key: const ValueKey('details-custom-notifications'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.notifications_none_rounded, color: AppColors.medBlue),
                    title: Text('Custom notifications', style: AppText.bodyPrimary),
                    trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                    onTap: () => context.push(AppRoutes.chatNotifications(conv.id)),
                  ),
                ],
              ),
            ),
          ),
          FadeSlideIn.staggered(
            3,
            _Section(
              title: 'Chat settings',
              child: AppPressable(
                onTap: () => _pickDisappearTimer(context, ref, conv),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.timer_outlined,
                    color: AppColors.medBlue,
                  ),
                  title:
                      Text('Disappearing messages', style: AppText.bodyPrimary),
                  subtitle: Text(
                    'New messages disappear after the selected time',
                    style: AppText.caption,
                  ),
                  trailing: Text(
                    kDisappearOptions[conv.disappearAfterSec] ?? 'Off',
                    style: AppText.caption.copyWith(
                      color: AppColors.medBlue,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDisappearTimer(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) async {
    final picked = await showModalBottomSheet<Object?>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Text('Disappearing messages', style: AppText.heading),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Text(
                'New messages in this chat will disappear after the selected '
                'duration. Existing messages are not affected.',
                style: AppText.caption,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final entry in kDisappearOptions.entries)
              ListTile(
                title: Text(entry.value, style: AppText.bodyPrimary),
                trailing:
                    (conv.disappearAfterSec ?? _off) == (entry.key ?? _off)
                    ? const Icon(Icons.check, color: AppColors.medBlue)
                    : null,
                // Wrap null (Off) in a sentinel so it survives the pop.
                onTap: () => Navigator.of(sheetCtx).pop(entry.key ?? _off),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (picked == null) return; // sheet dismissed
    final seconds = picked == _off ? null : picked as int;
    if (seconds == conv.disappearAfterSec) return;
    try {
      await ref
          .read(chatRepositoryProvider)
          .updateSettings(conv.id, disappearAfterSec: seconds);
      await ref.read(conversationsProvider.notifier).refresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(e))));
      }
    }
  }
}

/// Sentinel for the "Off" option so a null pick is distinguishable from a
/// dismissed sheet.
const _off = 'off';

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenHorizontal,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.xs,
              bottom: AppSpacing.sm,
            ),
            child: Text(title.toUpperCase(), style: AppText.label),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadii.rLg,
              border: Border.all(color: AppColors.border),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}
