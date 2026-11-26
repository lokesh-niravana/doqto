import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/api/api_client.dart';
import '../../../data/models/network_profile.dart';
import '../../../state/network_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/connect_button.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/inline_banner.dart';
import '../../widgets/section_card.dart';
import '../../widgets/report_message_sheet.dart';
import '../../widgets/root_back_button.dart';
import '../settings/blocked_list_screen.dart';
import '../../../core/utils/avatar_urls.dart';
import '../../../core/utils/async_retry.dart';

/// True while "Message" is creating/opening the thread for a user, so a
/// double tap cannot fire the request twice.
final _startingChatProvider =
    StateProvider.autoDispose.family<bool, String>((ref, userId) => false);

/// Self-loading person profile addressed by user id. Reachable via
/// `/people/:userId` and the `doqto:///people/<id>` deep link. Sections render
/// nothing when empty (never a locked placeholder).
class PersonProfileScreen extends ConsumerWidget {
  final String userId;
  const PersonProfileScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(relationshipProvider(userId));
    // Watched so the flag lives exactly as long as this screen, and so the
    // Message button can show progress while the thread is created.
    final startingChat = ref.watch(_startingChatProvider(userId));
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(
        // Opened from a link this is the only route: still a way out.
        leading: const RootBackButton(),
        title: const Text('Doctor'),
        actions: [
          if (async.hasValue)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: 'More',
              onPressed: () => _openMenu(context, ref),
            ),
        ],
      ),
      body: async.whenRetrying(
        loading: () => const _ProfileSkeleton(),
        error: (e, _) => _Unavailable(
          error: e,
          onRetry: () => ref.invalidate(relationshipProvider(userId)),
        ),
        data: (p) => _ProfileBody(
          profile: p,
          onMessage: () => _startChat(context, ref),
          messageLoading: startingChat,
          onUnblock: () => _confirmUnblock(context, ref),
        ),
      ),
    );
  }

  Future<void> _startChat(BuildContext context, WidgetRef ref) async {
    // A second tap while the first request is in flight would open (or
    // request) the thread twice.
    final busy = ref.read(_startingChatProvider(userId).notifier);
    if (busy.state) return;
    busy.state = true;
    try {
      final conv = await ref.read(chatRepositoryProvider).createConversation(
            type: ConversationType.direct,
            name: null,
            memberIds: [userId],
          );
      if (!context.mounted) return;
      openConversation(context, conv.id);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    } finally {
      // Gone with the screen if it was closed meanwhile.
      if (busy.mounted) busy.state = false;
    }
  }

  void _openMenu(BuildContext context, WidgetRef ref) {
    final state = ref.read(relationshipProvider(userId)).valueOrNull?.relationship
        .connectionState;
    final blocked = state == RelationshipState.blocked;
    final connected = state == RelationshipState.connected;
    final muted = ref.read(mutedUsersProvider).value?.contains(userId) ?? false;
    showModalBottomSheet<void>(
      context: context,
      // Sized to its content and scrollable, so nothing clips at large
      // text or on a short screen.
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.9,
          ),
          child: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('profile-mute'),
              leading: Icon(
                muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
              ),
              title: Text(
                muted ? Strings.profileUnmuteNotifications : Strings.profileMuteNotifications,
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _toggleMute(context, ref, !muted);
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text(Strings.netReport),
              onTap: () {
                Navigator.of(ctx).pop();
                _report(context, ref);
              },
            ),
            // Otherwise reachable only by long-pressing a row in Connections.
            if (connected)
              ListTile(
                key: const ValueKey('profile-remove-connection'),
                leading: const Icon(Icons.person_remove_outlined, color: AppColors.red),
                title: Text(
                  Strings.netRemoveConnection,
                  style: TextStyle(color: AppColors.red),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _confirmRemoveConnection(context, ref);
                },
              ),
            if (blocked)
              ListTile(
                key: const ValueKey('profile-unblock'),
                leading: const Icon(Icons.lock_open_outlined),
                title: const Text(Strings.netUnblock),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _confirmUnblock(context, ref);
                },
              )
            else
              ListTile(
                key: const ValueKey('profile-block'),
                leading: const Icon(Icons.block, color: AppColors.red),
                title: const Text(Strings.netBlock),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _confirmBlock(context, ref);
                },
              ),
          ],
        ),
          ),
        ),
      ),
    );
  }

  /// Same wording, Cancel and red action as the Connections long-press sheet.
  Future<void> _confirmRemoveConnection(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(Strings.netRemoveConnection),
        content: const Text(Strings.netRemoveConnectionConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(Strings.cancel),
          ),
          TextButton(
            key: const ValueKey('profile-remove-connection-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text(Strings.netRemoveConnection),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      // Drops the row from Connections and flips this profile to Connect.
      await ref.read(connectionsProvider.notifier).remove(userId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(Strings.netConnectionRemovedToast)),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }

  Future<void> _confirmUnblock(BuildContext context, WidgetRef ref) async {
    final profile = ref.read(relationshipProvider(userId)).valueOrNull;
    if (profile == null) return;
    final card = PersonCard(
      id: profile.id,
      fullName: profile.fullName,
      headline: profile.headline,
      specialty: profile.specialty,
      locationLabel: profile.locationLabel,
      avatarColor: profile.avatarColor,
      avatarUrl: profile.avatarUrl,
      avatarPresignedUrl: profile.avatarPresignedUrl,
      degree: ConnectionDegree.out,
      mutualCount: 0,
    );
    // One dialog + one wording, shared with the blocked list. The list
    // notifier does the call; the profile just mirrors the new state.
    final done = await BlockedListScreen.confirmUnblock(context, ref, card);
    if (done && ref.exists(relationshipProvider(userId))) {
      ref.read(relationshipProvider(userId).notifier).refresh();
    }
  }

  /// Mute a person (M1 `mutes`): no pushes or in-app banners from them in
  /// any chat. Nothing else changes — they can still message and see me.
  Future<void> _toggleMute(BuildContext context, WidgetRef ref, bool mute) async {
    try {
      await ref.read(mutedUsersProvider.notifier).setMuted(userId, mute);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(mute ? Strings.profileMutedToast : Strings.profileUnmutedToast),
      ));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }

  Future<void> _report(BuildContext context, WidgetRef ref) async {
    // Ask why, the same way a message report does: a bare "other" gives
    // whoever reviews it nothing to act on.
    final report = await showReportMessageSheet(context, title: Strings.netReportPersonTitle);
    if (report == null || !context.mounted) return;
    try {
      await ref.read(networkRepositoryProvider).report(
            subjectId: userId,
            reason: report.reason.wire,
            details: report.details,
          );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(Strings.netReportedToast)),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }

  Future<void> _confirmBlock(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(Strings.netBlock),
        content: const Text(Strings.netBlockConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(Strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text(Strings.netBlock),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(connectionsProvider.notifier).block(userId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(Strings.netBlockedToast)),
      );
      // Stay: the profile now shows the blocked banner with Unblock.
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }
}

class _ProfileBody extends ConsumerWidget {
  final NetworkProfile profile;
  final VoidCallback onMessage;
  final VoidCallback onUnblock;

  /// True while the thread is being created: the Message button spins.
  final bool messageLoading;
  const _ProfileBody({
    required this.profile,
    required this.onMessage,
    required this.onUnblock,
    this.messageLoading = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rel = profile.relationship;
    final blocked = rel.connectionState == RelationshipState.blocked;
    // ConnectButton already IS the message button when connected, and for an
    // unconnected colleague — don't double up in either case.
    final showMessageButton = !blocked &&
        rel.connectionState != RelationshipState.connected &&
        rel.canMessage != CanMessage.denied &&
        !(rel.connectionState == RelationshipState.none && rel.isColleague);

    return ListView(
      // Explicit padding drops the automatic safe-area inset; add it back so
      // the last row clears the home indicator.
      padding: EdgeInsets.only(
        top: AppSpacing.lg,
        bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        // Header: hero avatar pairs with member-avatar-<id> across the app.
        Column(
          children: [
            DoctorAvatar(
              initials: profile.initials,
              colorIndex: profile.avatarIndex,
              size: AvatarSize.xxl,
              imageUrl: userAvatarUrl(profile.id, profile.avatarUrl),
              heroTag: 'member-avatar-${profile.id}',
            ),
            const SizedBox(height: AppSpacing.md),
            Text(profile.fullName,
                style: AppText.display, textAlign: TextAlign.center),
            if (profile.statusLabel() case final status?) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(status, key: const ValueKey('person-status'),
                  style: AppText.body, textAlign: TextAlign.center),
            ],
            if (_notEmpty(profile.headline)) ...[
              const SizedBox(height: AppSpacing.xs),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenHorizontal),
                child: Text(profile.headline!,
                    style: AppText.body, textAlign: TextAlign.center),
              ),
            ],
            if (_notEmpty(profile.specialty)) ...[
              const SizedBox(height: AppSpacing.sm),
              _Chip(profile.specialty!),
            ],
            if (_notEmpty(profile.locationLabel)) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.location_on_outlined,
                      size: 14, color: AppColors.textMuted),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(profile.locationLabel!,
                        style: AppText.caption),
                  ),
                ],
              ),
            ],
          ],
        ),

        const SizedBox(height: AppSpacing.lg),

        // Primary connection control + optional secondary Message button.
        // A doctor I blocked gets a banner and Unblock instead.
        if (blocked)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: InlineBanner(
              key: ValueKey('profile-blocked-banner'),
              tone: BannerTone.neutral,
              icon: Icons.block,
              text: Strings.privacyBlockedBanner,
            ),
          ),
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: AppSpacing.screenHorizontal),
          child: Column(
            children: [
              if (blocked)
                AppButton(
                  key: const ValueKey('profile-unblock-button'),
                  label: Strings.netUnblock,
                  icon: Icons.lock_open_outlined,
                  variant: AppButtonVariant.secondary,
                  expand: true,
                  onPressed: onUnblock,
                )
              else
                ConnectButton(
                  userId: profile.id,
                  onMessage: onMessage,
                  messageLoading: messageLoading,
                  expand: true,
                ),
              if (showMessageButton) ...[
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: Strings.netMessage,
                  icon: Icons.chat_bubble_outline,
                  variant: AppButtonVariant.ghost,
                  expand: true,
                  loading: messageLoading,
                  onPressed: onMessage,
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.lg),

        // Mutuals line (renders nothing if no label/count).
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: AppSpacing.screenHorizontal),
          child: FadeSlideIn.staggered(
            0,
            _MutualsSection(
              mutualCount: rel.mutualCount,
              contextLabel: rel.contextLabel,
            ),
          ),
        ),

        // About.
        if (_notEmpty(profile.about))
          FadeSlideIn.staggered(
            1,
            _Section(
              title: Strings.profileAbout,
              child: Text(profile.about!, style: AppText.bodyPrimary),
            ),
          ),

        // Experience.
        if (profile.yearsOfExperience != null)
          FadeSlideIn.staggered(
            2,
            _Section(
              title: Strings.profileExperience,
              child: Text(
                '${profile.yearsOfExperience} '
                'year${profile.yearsOfExperience == 1 ? '' : 's'}',
                style: AppText.bodyPrimary,
              ),
            ),
          ),

        // Skills.
        if (profile.skills.isNotEmpty)
          FadeSlideIn.staggered(
            3,
            _Section(
              title: Strings.profileSkills,
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [for (final s in profile.skills) _Chip(s)],
              ),
            ),
          ),

        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }

  bool _notEmpty(String? s) => s != null && s.trim().isNotEmpty;
}

class _MutualsSection extends ConsumerWidget {
  final int mutualCount;
  final String? contextLabel;
  const _MutualsSection({required this.mutualCount, required this.contextLabel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // We only have count + label from the profile payload; no avatar list.
    final hasLabel = (contextLabel != null && contextLabel!.trim().isNotEmpty);
    if (!hasLabel && mutualCount <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        children: [
          Icon(Icons.people_alt_outlined, size: 18, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              hasLabel
                  ? contextLabel!
                  : (mutualCount == 1
                      ? '1 mutual connection'
                      : '$mutualCount mutual connections'),
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenHorizontal,
        AppSpacing.sm,
        AppSpacing.screenHorizontal,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding:
                const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.sm),
            child: Semantics(header: true, child: Text(title.toUpperCase(), style: AppText.label)),
          ),
          SectionCard(
            child: SizedBox(
              width: double.infinity,
              child: Align(alignment: Alignment.centerLeft, child: child),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.medBlueLight,
        borderRadius: AppRadii.rFull,
      ),
      child: Text(
        label,
        style: AppText.caption.copyWith(
          color: AppColors.medBlueDark,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _Unavailable({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    // Gone, blocked or private: trying again will not help. Anything else
    // (offline, a server error) gets the reason and a Retry.
    final e = error;
    final gone = e is ApiException && (e.status == 403 || e.status == 404);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              gone ? Icons.person_off_outlined : Icons.wifi_off_rounded,
              size: 48,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: AppSpacing.md),
            Semantics(
              container: true,
              liveRegion: true,
              child: Text(
                gone ? Strings.netErrorUserUnavailable : ErrorMessages.forApi(e),
                style: AppText.body,
                textAlign: TextAlign.center,
              ),
            ),
            if (!gone) ...[
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                key: const ValueKey('person-retry'),
                label: Strings.retry,
                icon: Icons.refresh_rounded,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    // The grey blocks are only drawn; a screen reader hears "Loading" once.
    return Semantics(
      container: true,
      label: Strings.loading,
      liveRegion: true,
      child: ExcludeSemantics(
        child: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenHorizontal,
            vertical: AppSpacing.xl,
          ),
          children: [
            Center(child: AppSkeleton.circle(size: 104)),
            const SizedBox(height: AppSpacing.md),
            Center(child: AppSkeleton.line(width: 160, height: 16)),
            const SizedBox(height: AppSpacing.sm),
            Center(child: AppSkeleton.line(width: 96)),
            const SizedBox(height: AppSpacing.xl),
            AppSkeleton.block(height: 44),
            const SizedBox(height: AppSpacing.lg),
            AppSkeleton.block(height: 88),
            const SizedBox(height: AppSpacing.lg),
            AppSkeleton.block(height: 120),
          ],
        ),
      ),
    );
  }
}
