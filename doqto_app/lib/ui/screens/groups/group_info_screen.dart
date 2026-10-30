import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/group.dart';
import '../../../state/auth_state.dart';
import '../../../state/groups_state.dart';
import '../../widgets/app_pill.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/member_row.dart';
import '../../widgets/primary_button.dart';

/// Group info, opened from the group chat's header (WhatsApp's "Group info"):
/// who the group is, what it's for, who is in it, and the way out. A doctor
/// who isn't a member (a pending invite) lands here instead of the chat.
class GroupInfoScreen extends ConsumerWidget {
  final String groupId;
  const GroupInfoScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(groupDetailProvider(groupId));
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.groupInfoTitle)),
      body: async.when(
        loading: () => const SkeletonList(),
        error: (e, _) => _InlineError(
          message: ErrorMessages.forApi(e),
          onRetry: () => ref.invalidate(groupDetailProvider(groupId)),
        ),
        data: (group) => ListView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
          ),
          children: [
            _Identity(group: group),
            const SizedBox(height: AppSpacing.sm),
            _About(group: group),
            const SizedBox(height: AppSpacing.sm),
            _Members(groupId: group.id),
            if (group.isMember) ...[
              const SizedBox(height: AppSpacing.sm),
              _Section(
                child: ListTile(
                  leading: const Icon(Icons.logout, color: AppColors.red),
                  title: Text(
                    Strings.groupLeave,
                    style: AppText.body.copyWith(color: AppColors.red),
                  ),
                  onTap: () => _leave(context, ref),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final me = ref.read(authProvider).user;
    if (me == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Text(Strings.netLeaveGroupConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(Strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text(Strings.groupLeave),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(groupDetailProvider(groupId).notifier).leave(me.id);
      messenger.showSnackBar(
        const SnackBar(content: Text(Strings.groupLeftToast)),
      );
      // Both this screen and the chat behind it are closed to a non-member.
      if (context.mounted) context.go(AppRoutes.groups);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }
}

/// White band on the grey page, one per section.
class _Section extends StatelessWidget {
  final Widget child;
  const _Section({required this.child});

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: AppColors.white, child: child);
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenHorizontal,
          AppSpacing.md,
          AppSpacing.screenHorizontal,
          AppSpacing.xs,
        ),
        child: Text(text, style: AppText.label),
      );
}

class _Identity extends StatelessWidget {
  final Group group;
  const _Identity({required this.group});

  @override
  Widget build(BuildContext context) => _Section(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenHorizontal,
            AppSpacing.md,
            AppSpacing.screenHorizontal,
            AppSpacing.lg,
          ),
          child: Column(
            children: [
              DoctorAvatar(
                initials: group.initials,
                colorIndex: group.avatarIndex,
                imageUrl: group.avatarUrl,
                size: AvatarSize.xxl,
                heroTag: 'group-avatar-${group.id}',
              ),
              const SizedBox(height: AppSpacing.md),
              Text(group.name,
                  style: AppText.heading, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.xs),
              Text(
                Strings.groupMemberCount(group.memberCount),
                style: AppText.caption,
              ),
            ],
          ),
        ),
      );
}

class _About extends StatelessWidget {
  final Group group;
  const _About({required this.group});

  String get _dmRule => switch (group.memberDmPolicy) {
        'open' => Strings.groupsDmOpen,
        'disabled' => Strings.groupsDmDisabled,
        _ => Strings.groupsDmRequest,
      };

  static String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final l = d.toLocal();
    return '${months[l.month - 1]} ${l.day}, ${l.year}';
  }

  Widget _line(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenHorizontal,
          vertical: AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppText.caption),
            const SizedBox(height: 2),
            Text(value, style: AppText.body),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => _Section(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionLabel(Strings.groupAboutLabel),
            if (group.description != null && group.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.screenHorizontal,
                  0,
                  AppSpacing.screenHorizontal,
                  AppSpacing.xs,
                ),
                child: Text(group.description!, style: AppText.body),
              ),
            _line(Strings.groupsRulesLabel, Strings.groupsPolicyInviteOnly),
            _line(Strings.groupsMemberMessagingLabel, _dmRule),
            if (group.createdAt != null)
              _line(Strings.groupsCreatedLabel, _formatDate(group.createdAt!)),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      );
}

class _Members extends ConsumerWidget {
  final String groupId;
  const _Members({required this.groupId});

  Widget? _roleBadge(GroupRole role) => switch (role) {
        GroupRole.owner => const AppPill(label: 'Owner', tone: PillTone.brand),
        GroupRole.admin => const AppPill(label: 'Admin', tone: PillTone.brand),
        GroupRole.moderator =>
          const AppPill(label: 'Mod', tone: PillTone.neutral),
        _ => null,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(groupMembersProvider(groupId));
    final meId = ref.watch(authProvider).user?.id;
    return _Section(
      child: async.when(
        loading: () => const SizedBox(height: 180, child: SkeletonList()),
        error: (e, _) => _InlineError(
          message: ErrorMessages.forApi(e),
          onRetry: () => ref.invalidate(groupMembersProvider(groupId)),
        ),
        data: (members) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel(Strings.groupMemberCount(members.length)),
            if (members.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
                child: Text(Strings.groupsNoMembers, style: AppText.body),
              ),
            for (final m in members)
              MemberRow(
                avatar: DoctorAvatar(
                  initials: m.initials,
                  colorIndex: m.avatarIndex,
                  imageUrl: m.avatarUrl,
                ),
                title: m.userId == meId ? Strings.groupYou : m.fullName,
                subtitle: m.specialty ?? m.headline,
                trailing: _roleBadge(m.role),
                // Your own row opens nothing; anyone else opens their profile.
                onTap: m.userId == meId
                    ? null
                    : () => context.push(AppRoutes.person(m.userId)),
              ),
          ],
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _InlineError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, style: AppText.caption, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              label: Strings.retry,
              variant: AppButtonVariant.secondary,
              onPressed: onRetry,
            ),
          ],
        ),
      );
}
