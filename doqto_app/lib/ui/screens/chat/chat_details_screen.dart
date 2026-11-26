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
import '../../widgets/load_failed.dart';
import '../../widgets/primary_button.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/utils/chat_list_filters.dart';
import 'chat_list_screen.dart' show ConversationActions;
import '_conversation_display.dart';
import '../../../core/utils/avatar_urls.dart';

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
    final convsAsync = ref.watch(conversationsProvider);
    // `valueOrNull`, not `asData`: a failed reload keeps the chats it had.
    final convs = convsAsync.valueOrNull ?? const <Conversation>[];
    final conv = convs.where((c) => c.id == conversationId).firstOrNull;
    final currentOrg = ref.watch(orgProvider).current;
    final orgMembers = currentOrg == null
        ? const <OrgMember>[]
        : (ref.watch(orgMembersProvider(currentOrg.id)).asData?.value ??
              const <OrgMember>[]);

    if (conv == null) {
      // Still loading (or a Retry in flight): wait. Loaded without this
      // chat — deleted, or the user was removed from it — say so; the
      // spinner used to turn forever here.
      final waiting =
          convsAsync.isLoading && (!convsAsync.hasValue || convsAsync.hasError);
      return Scaffold(
        appBar: AppBar(title: const Text('Chat info')),
        body: waiting
            ? const Center(child: CircularProgressIndicator(semanticsLabel: Strings.loading))
            : convsAsync.hasError && !convsAsync.hasValue
            ? Center(
                child: LoadFailed(
                  message: ErrorMessages.forApi(convsAsync.error!),
                  onRetry: () => ref.invalidate(conversationsProvider),
                ),
              )
            : Center(
                key: const ValueKey('details-unavailable'),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chat_bubble_outline_rounded, size: 48, color: AppColors.gray400),
                      const SizedBox(height: AppSpacing.lg),
                      Semantics(
                        container: true,
                        liveRegion: true,
                        child: Text(
                          Strings.chatUnavailable,
                          style: AppText.heading,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      AppButton(
                        key: const ValueKey('details-unavailable-back'),
                        label: Strings.chatUnavailableBack,
                        variant: AppButtonVariant.secondary,
                        // Out of the dead chat altogether, not back into its
                        // thread.
                        onPressed: () => context.go(AppRoutes.chats),
                      ),
                    ],
                  ),
                ),
              ),
      );
    }

    final muted = conv.prefs.isMuted();
    final unread = isConversationUnread(conv);
    final isGroup = conv.type == ConversationType.group;
    // Everything the chat row's swipe "More" sheet offers, as visible rows:
    // a swipe is not discoverable, and for Clear chat it was the only way in.
    Widget actionRow({
      required String keyName,
      required IconData icon,
      required String label,
      required Future<void> Function() onTap,
      bool destructive = false,
    }) => AppPressable(
      key: ValueKey(keyName),
      onTap: onTap,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: destructive ? AppColors.red : AppColors.medBlue),
        title: Text(
          label,
          style: destructive
              ? AppText.bodyPrimary.copyWith(color: AppColors.red)
              : AppText.bodyPrimary,
        ),
      ),
    );

    final display = conversationDisplay(
      c: conv,
      orgMembers: orgMembers,
      meId: me?.id,
      fallbackColorIndex: 0,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Chat info')),
      body: ListView(
        // Explicit padding drops the automatic safe-area inset; add it back so
        // the last row clears the home indicator.
        padding: EdgeInsets.only(
          top: AppSpacing.lg,
          bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
        ),
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
                    imageUrl: userAvatarUrl(display.otherUser?.id, display.otherUser?.avatarUrl),
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
              child: Column(
                children: [
                  AppPressable(
                    key: const ValueKey('details-media'),
                    onTap: () => context.push(AppRoutes.mediaGallery(conv.id)),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.perm_media_outlined, color: AppColors.medBlue),
                      title: Text(Strings.mediaGalleryTitle, style: AppText.bodyPrimary),
                      trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                    ),
                  ),
                  AppPressable(
                    key: const ValueKey('details-starred'),
                    onTap: () => context.push(AppRoutes.starredIn(conv.id)),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.star_outline_rounded, color: AppColors.medBlue),
                      title: Text(Strings.chatStarredMessages, style: AppText.bodyPrimary),
                      trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                    ),
                  ),
                ],
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
          FadeSlideIn.staggered(
            4,
            _Section(
              title: Strings.chatDetailsActions,
              child: Column(
                children: [
                  actionRow(
                    keyName: 'details-pin',
                    icon: conv.prefs.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                    label: conv.prefs.isPinned ? Strings.chatUnpin : Strings.chatPin,
                    onTap: () => ConversationActions.togglePin(context, ref, conv),
                  ),
                  actionRow(
                    keyName: 'details-mute',
                    icon: muted
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                    label: muted ? Strings.chatUnmute : Strings.chatMute,
                    onTap: () => ConversationActions.toggleMute(context, ref, conv),
                  ),
                  actionRow(
                    keyName: 'details-unread',
                    icon: unread
                        ? Icons.mark_chat_read_outlined
                        : Icons.mark_chat_unread_outlined,
                    label: unread ? Strings.chatMarkRead : Strings.chatMarkUnread,
                    onTap: () => ConversationActions.toggleMarkUnread(context, ref, conv),
                  ),
                  actionRow(
                    keyName: 'details-archive',
                    icon: conv.prefs.archived
                        ? Icons.unarchive_outlined
                        : Icons.archive_outlined,
                    label: conv.prefs.archived ? Strings.chatUnarchive : Strings.chatArchive,
                    onTap: () => ConversationActions.toggleArchive(context, ref, conv),
                  ),
                  actionRow(
                    keyName: 'details-clear',
                    icon: Icons.cleaning_services_outlined,
                    label: Strings.chatClear,
                    destructive: true,
                    // Asks first (Cancel / red Clear chat), as the sheet does.
                    onTap: () => ConversationActions.clearChat(context, ref, conv),
                  ),
                  actionRow(
                    keyName: 'details-delete',
                    icon: Icons.delete_outline,
                    label: isGroup ? Strings.chatLeaveGroup : Strings.chatDeleteChat,
                    destructive: true,
                    onTap: () async {
                      await ConversationActions.deleteChat(context, ref, conv);
                      if (!context.mounted) return;
                      // Gone: leave its screens for the chat list.
                      final still = ref
                          .read(conversationsProvider)
                          .valueOrNull
                          ?.any((c) => c.id == conv.id);
                      if (still == false) context.go(AppRoutes.chats);
                    },
                  ),
                ],
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
      // Scrolls, and may grow past half the screen: seven rows clip on a
      // small phone or at large text otherwise.
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
        key: const ValueKey('disappear-sheet-scroll'),
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
                selected: (conv.disappearAfterSec ?? _off) == (entry.key ?? _off),
                selectedColor: AppColors.textPrimary,
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
            child: Semantics(header: true, child: Text(title.toUpperCase(), style: AppText.label)),
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
