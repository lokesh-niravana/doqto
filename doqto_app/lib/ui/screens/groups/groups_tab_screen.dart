import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/motion.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/group.dart';
import '../../../state/groups_state.dart';
import '../../widgets/app_pill.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/refresh_feedback.dart';
import '../../widgets/member_row.dart';
import '../../widgets/primary_button.dart';
import '../../../core/utils/avatar_urls.dart';
import '../home/main_shell.dart';
import 'group_info_screen.dart' show confirmDialog;
import '../../../core/utils/async_retry.dart';

/// The Groups tab: my groups only — groups are not discoverable by browsing.
/// Create is a header action (the center FAB slot is owned by the mic).
class GroupsTabScreen extends ConsumerWidget {
  const GroupsTabScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(
        title: const Text(Strings.netTabGroups),
        actions: [
          TextButton.icon(
            onPressed: () => context.push(AppRoutes.groupsCreate),
            icon: const Icon(Icons.add, size: 20),
            label: const Text(Strings.groupsCreate),
          ),
        ],
      ),
      body: _buildMyGroups(context, ref),
    );
  }

  Widget _buildMyGroups(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myGroupsProvider);
    return async.whenRetrying(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const SkeletonList(),
      error: (e, _) => _ErrorPane(
        message: ErrorMessages.forApi(e),
        onRetry: () => ref.invalidate(myGroupsProvider),
      ),
      data: (data) {
        if (data.isEmpty && data.invitedError == null) {
          return const _EmptyPane(
            icon: Icons.groups_outlined,
            text: Strings.netEmptyGroups,
          );
        }
        // member first, then invited.
        final rows = <Group>[...data.member, ...data.invited];
        // The invitations fetch failed on its own: one more row saying so.
        final invitesFailed = data.invitedError != null;
        return RefreshIndicator(
          onRefresh: () => refreshWithFeedback(
            context,
            () => ref
                .read(myGroupsProvider.notifier)
                .refresh(rethrowOnError: true),
          ),
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              top: AppSpacing.sm,
              bottom: MediaQuery.paddingOf(context).bottom + kMicButtonRise + AppSpacing.xl,
            ),
            itemCount: rows.length + (invitesFailed ? 1 : 0),
            itemBuilder: (context, i) => i >= rows.length
                ? const _InvitesFailedRow()
                : FadeSlideIn.staggered(
              i,
              _GroupRow(
                group: rows[i],
                onTap: () => context.push(AppRoutes.group(rows[i].id)),
              ),
              enabled: i <= AppMotion.staggerCap,
            ),
          ),
        );
      },
    );
  }
}

/// A "My groups" list row: avatar, name, member count, and for a group you
/// have been asked to join but have not accepted yet, an Invited chip plus
/// Accept / Decline right on the row.
class _GroupRow extends ConsumerWidget {
  final Group group;
  final VoidCallback onTap;
  const _GroupRow({required this.group, required this.onTap});

  Future<void> _accept(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    // The row moves from "Invited" to the member list as soon as the
    // optimistic state flips, so this context is dead after the await.
    final router = GoRouter.maybeOf(context); // null in widget tests
    try {
      await ref.read(myGroupsProvider.notifier).acceptInvite(group);
      messenger.showSnackBar(
        const SnackBar(content: Text(Strings.groupJoinedToast)),
      );
      router?.push(AppRoutes.group(group.id));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }

  Future<void> _decline(BuildContext context, WidgetRef ref) async {
    // Declining discards the invite; only a new one brings it back.
    final ok = await confirmDialog(
      context,
      message: Strings.groupDeclineConfirm(group.name),
      action: Strings.groupDecline,
    );
    if (!ok || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(myGroupsProvider.notifier).declineInvite(group);
      messenger.showSnackBar(
        const SnackBar(content: Text(Strings.groupDeclinedToast)),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invited = group.membershipTag == GroupMembershipTag.invited;
    final subtitle = _memberCountLabel(group.memberCount);
    final row = MemberRow(
      key: ValueKey('group-row-${group.id}'),
      avatar: DoctorAvatar(
        initials: group.initials,
        colorIndex: group.avatarIndex,
        imageUrl: groupAvatarUrl(group.id, group.avatarUrl),
        heroTag: 'group-avatar-${group.id}',
      ),
      title: group.name,
      subtitle: subtitle,
      trailing: invited
          ? const AppPill(label: Strings.groupInvited, tone: PillTone.brand)
          : null,
      onTap: onTap,
    );
    if (!invited) return row;
    return Column(
      children: [
        row,
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenHorizontal,
            0,
            AppSpacing.screenHorizontal,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: AppButton(
                  key: ValueKey('group-decline-${group.id}'),
                  label: Strings.groupDecline,
                  variant: AppButtonVariant.secondary,
                  onPressed: () => _decline(context, ref),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  key: ValueKey('group-accept-${group.id}'),
                  label: Strings.groupAccept,
                  onPressed: () => _accept(context, ref),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Closes the invitations section when its fetch failed while the member
/// list loaded: without it the tab simply showed no invitations.
class _InvitesFailedRow extends ConsumerStatefulWidget {
  const _InvitesFailedRow();

  @override
  ConsumerState<_InvitesFailedRow> createState() => _InvitesFailedRowState();
}

class _InvitesFailedRowState extends ConsumerState<_InvitesFailedRow> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    // On success the row goes with the error; on failure it stays put.
    await ref.read(myGroupsProvider.notifier).refresh();
    if (mounted) setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('group-invites-error'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenHorizontal,
        AppSpacing.sm,
        AppSpacing.screenHorizontal,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const InlineError(Strings.groupInvitesLoadFailed),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            key: const ValueKey('group-invites-retry'),
            label: Strings.retry,
            icon: Icons.refresh_rounded,
            variant: AppButtonVariant.ghost,
            expand: true,
            loading: _retrying,
            onPressed: _retrying ? null : _retry,
          ),
        ],
      ),
    );
  }
}

String _memberCountLabel(int n) => n == 1 ? '1 member' : '$n members';

class _EmptyPane extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyPane({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.gray400),
            const SizedBox(height: AppSpacing.md),
            // Announced when it replaces the loading state.
            Semantics(
              container: true,
              liveRegion: true,
              child: Text(text, style: AppText.body, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorPane({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 40, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.md),
            // Announced when it replaces the loading state.
            Semantics(
              container: true,
              liveRegion: true,
              child: Text(message, style: AppText.caption, textAlign: TextAlign.center),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
                label: Strings.retry,
                icon: Icons.refresh_rounded,
                onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
