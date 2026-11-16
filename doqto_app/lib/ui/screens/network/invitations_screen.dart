import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/datetime_format.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/network_profile.dart';
import '../../../state/network_state.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/invitation_card.dart';
import '../../widgets/member_row.dart';
import '../../widgets/primary_button.dart';
import '../../../core/utils/avatar_urls.dart';

/// Full invitations inbox: Received (accept/ignore, optimistic) + Sent (pending
/// with withdraw). Reachable from the Network tab's "See all" entry.
class InvitationsScreen extends ConsumerStatefulWidget {
  const InvitationsScreen({super.key});

  @override
  ConsumerState<InvitationsScreen> createState() => _InvitationsScreenState();
}

class _InvitationsScreenState extends ConsumerState<InvitationsScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.netInvitations)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenHorizontal,
              vertical: AppSpacing.sm,
            ),
            child: AppSegmented(
              tabs: const [Strings.netReceived, Strings.netSent],
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ),
          Expanded(
            child: _tab == 0 ? const _ReceivedList() : const _SentList(),
          ),
        ],
      ),
    );
  }
}

class _ReceivedList extends ConsumerWidget {
  const _ReceivedList();

  Future<void> _run(BuildContext context, Future<void> Function() action,
      String? toast) async {
    try {
      await action();
      if (toast != null && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(toast)));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(invitationsProvider);
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SkeletonList(),
      error: (e, _) => _ErrorPane(
        message: ErrorMessages.forApi(e),
        onRetry: () => ref.read(invitationsProvider.notifier).refresh(),
      ),
      data: (invites) {
        if (invites.isEmpty) {
          return const _EmptyPane(
            icon: Icons.mark_email_read_outlined,
            text: Strings.netEmptyInvitations,
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.read(invitationsProvider.notifier).refresh(),
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              AppSpacing.screenHorizontal,
              AppSpacing.md,
              AppSpacing.screenHorizontal,
              MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
            ),
            itemCount: invites.length,
            separatorBuilder: (_, i) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, i) {
              final inv = invites[i];
              return FadeSlideIn.staggered(
                i,
                InvitationCard(
                  invitation: inv,
                  onAccept: () => _run(
                    context,
                    () =>
                        ref.read(invitationsProvider.notifier).accept(inv),
                    Strings.netNowConnectedToast,
                  ),
                  onIgnore: () => _run(
                    context,
                    () =>
                        ref.read(invitationsProvider.notifier).ignore(inv),
                    null,
                  ),
                  onTap: inv.sender != null
                      ? () => context.push(AppRoutes.person(inv.sender!.id))
                      : null,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _SentList extends ConsumerWidget {
  const _SentList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sentInvitationsProvider);
    return async.when(
      loading: () => const SkeletonList(),
      skipLoadingOnReload: true,
      error: (e, _) => _ErrorPane(
        message: ErrorMessages.forApi(e),
        onRetry: () => ref.invalidate(sentInvitationsProvider),
      ),
      data: (invites) {
        if (invites.isEmpty) {
          return const _EmptyPane(
            icon: Icons.outbox_outlined,
            text: Strings.netEmptySent,
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.read(sentInvitationsProvider.notifier).refresh(),
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              top: AppSpacing.sm,
              bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
            ),
            itemCount: invites.length,
            itemBuilder: (context, i) => FadeSlideIn.staggered(
              i,
              _SentRow(invitation: invites[i]),
            ),
          ),
        );
      },
    );
  }
}

class _SentRow extends ConsumerStatefulWidget {
  final Invitation invitation;
  const _SentRow({required this.invitation});

  @override
  ConsumerState<_SentRow> createState() => _SentRowState();
}

class _SentRowState extends ConsumerState<_SentRow> {
  bool _withdrawing = false;

  Future<void> _withdraw() async {
    if (_withdrawing) return;
    setState(() => _withdrawing = true);
    try {
      await ref
          .read(sentInvitationsProvider.notifier)
          .withdraw(widget.invitation);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(Strings.netInviteWithdrawnToast)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _withdrawing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final party = widget.invitation.recipient;
    final elapsed = widget.invitation.createdAt != null
        ? formatChatListTime(widget.invitation.createdAt!)
        : '';
    return MemberRow(
      avatar: DoctorAvatar(
        initials: party?.initials ?? '?',
        colorIndex: party?.avatarIndex ?? 0,
        imageUrl: userAvatarUrl(party?.id, party?.avatarUrl),
        size: AvatarSize.lg,
      ),
      title: party?.fullName ?? '',
      subtitle: elapsed.isEmpty
          ? Strings.netPending
          : '${Strings.netPending} · $elapsed',
      onTap: party != null
          ? () => context.push(AppRoutes.person(party.id))
          : null,
      trailing: AppButton(
        label: Strings.netWithdraw,
        variant: AppButtonVariant.ghost,
        loading: _withdrawing,
        onPressed: _withdraw,
      ),
    );
  }
}

class _EmptyPane extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyPane({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: AppColors.gray400),
          const SizedBox(height: AppSpacing.md),
          Text(text, style: AppText.body, textAlign: TextAlign.center),
        ],
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
            Text(message, style: AppText.caption, textAlign: TextAlign.center),
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
