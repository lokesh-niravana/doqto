import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/organization.dart';
import '../../../state/auth_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/invite_code_card.dart';
import '../../widgets/primary_button.dart';

class MyOrgScreen extends ConsumerWidget {
  const MyOrgScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final org = ref.watch(orgProvider).current;
    final me = ref.watch(authProvider).user;
    return Scaffold(
      appBar: AppBar(title: Text(org?.name ?? 'My Org')),
      body: org == null
          ? const _NoOrg()
          : ref
                .watch(orgMembersProvider(org.id))
                .when(
                  loading: () => const SkeletonList(),
                  error: (e, _) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.wifi_off_rounded,
                            size: 40,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            ErrorMessages.forApi(e),
                            style: AppText.caption,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          AppButton(
                            label: 'Retry',
                            icon: Icons.refresh_rounded,
                            onPressed: () =>
                                ref.invalidate(orgMembersProvider(org.id)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  data: (members) {
                    final isAdmin =
                        me != null &&
                        members.any(
                          (m) => m.id == me.id && m.orgRole == OrgRole.admin,
                        );
                    final pending = org.status == OrgStatus.pending;
                    final lead = pending ? 1 : 0;
                    return RefreshIndicator(
                      // Pull to re-check verification and members.
                      onRefresh: () async {
                        await ref
                            .read(authProvider.notifier)
                            .refreshOrgStatus();
                        ref.invalidate(orgMembersProvider(org.id));
                      },
                      child: ListView(
                        // extendBody: keep last row clear of the floating nav bar.
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.screenHorizontal,
                          AppSpacing.screenHorizontal,
                          AppSpacing.screenHorizontal,
                          MediaQuery.paddingOf(context).bottom +
                              AppSpacing.screenHorizontal,
                        ),
                        children: [
                          if (pending) ...[
                            FadeSlideIn.staggered(0, const _PendingBanner()),
                            const SizedBox(height: AppSpacing.lg),
                          ],
                          if (isAdmin) ...[
                            FadeSlideIn.staggered(
                              lead,
                              InviteCodeCard(code: org.inviteCode),
                            ),
                            const SizedBox(height: AppSpacing.xl),
                          ],
                          FadeSlideIn.staggered(
                            lead + (isAdmin ? 1 : 0),
                            Text(
                              'MEMBERS (${org.memberCount})',
                              style: AppText.label,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          for (final (i, m) in members.indexed)
                            FadeSlideIn.staggered(
                              i + lead + (isAdmin ? 2 : 1),
                              _MemberRow(
                                member: m,
                                colorIndex: i,
                                isSelf: me != null && m.id == me.id,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

/// A pending org is a state of the org, not of the account: everything else
/// in the app keeps working while Doqto reviews it.
class _PendingBanner extends StatelessWidget {
  const _PendingBanner();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpacing.lg),
    decoration: BoxDecoration(
      color: AppColors.amberLight,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.schedule_rounded,
          color: AppColors.amberText,
          size: 20,
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pending verification',
                style: AppText.bodyPrimary.copyWith(color: AppColors.amberText),
              ),
              const SizedBox(height: 2),
              Text(
                'Doqto is reviewing this organization. Chats and your '
                'connections work as usual; groups open once it\'s verified.',
                style: AppText.caption.copyWith(color: AppColors.amberText),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _MemberRow extends ConsumerStatefulWidget {
  final OrgMember member;
  final int colorIndex;
  final bool isSelf;

  const _MemberRow({
    required this.member,
    required this.colorIndex,
    required this.isSelf,
  });

  @override
  ConsumerState<_MemberRow> createState() => _MemberRowState();
}

class _MemberRowState extends ConsumerState<_MemberRow> {
  bool _starting = false;

  Future<void> _startChat() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final conv = await ref
          .read(chatRepositoryProvider)
          .createConversation(
            type: ConversationType.direct,
            name: null,
            memberIds: [widget.member.id],
          );
      if (!mounted) return;
      openConversation(context, conv.id);
    } catch (e, st) {
      // The snackbar collapses every failure into one line; keep the real
      // error where a developer can see it.
      debugPrint('startChat failed: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _openProfile() {
    // Self opens the editable self view; other members open the addressable
    // networking profile by id (hero pairs on `member-avatar-<id>`).
    if (widget.isSelf) {
      context.push(AppRoutes.profile);
    } else {
      context.push(AppRoutes.person(widget.member.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    // AppPressable supplies scale/opacity press feedback; ListTile keeps the
    // ≥44pt row layout. The avatar Hero pairs with the member profile view
    // (`member-avatar-<id>`) — self opens the editable profile, so no hero.
    return AppPressable(
      onTap: _openProfile,
      minTarget: true,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: DoctorAvatar(
          initials: m.initials,
          colorIndex: widget.colorIndex,
          imageUrl: m.avatarPresignedUrl,
          heroTag: widget.isSelf ? null : 'member-avatar-${m.id}',
        ),
        title: Text(m.fullName),
        subtitle: Text(m.specialty ?? (widget.isSelf ? 'You' : '')),
        trailing: widget.isSelf
            ? null
            : SizedBox(
                width: 40,
                height: 40,
                child: _starting
                    ? const Padding(
                        padding: EdgeInsets.all(AppSpacing.sm),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        tooltip: 'Message',
                        icon: const Icon(Icons.chat_bubble_outline),
                        color: AppColors.medBlue,
                        onPressed: _startChat,
                      ),
              ),
      ),
    );
  }
}

/// Onboarding no longer forces anyone into an org (see docs/payments.md), so
/// this is the normal state for a new user — not an error. It offers the same
/// two doors the old org-selection step did.
class _NoOrg extends StatelessWidget {
  const _NoOrg();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: AppColors.medBlueLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.apartment_rounded,
                color: AppColors.medBlue,
                size: 30,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              Strings.orgNoneTitle,
              style: AppText.heading,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              Strings.orgNoneBody,
              style: AppText.body,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              label: Strings.orgNoneCreate,
              icon: Icons.add_rounded,
              expand: true,
              onPressed: () => context.push(AppRoutes.createOrg),
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              label: Strings.orgNoneJoin,
              icon: Icons.vpn_key_rounded,
              variant: AppButtonVariant.secondary,
              expand: true,
              onPressed: () => context.push(AppRoutes.joinOrg),
            ),
          ],
        ),
      ),
    );
  }
}
