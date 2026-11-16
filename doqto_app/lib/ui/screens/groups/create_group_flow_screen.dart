import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/network_profile.dart';
import '../../../state/groups_state.dart';
import '../../../state/network_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/member_row.dart';
import '../../widgets/search_bar.dart';
import '../../widgets/step_flow.dart';
import '../../../core/utils/avatar_urls.dart';

/// 2-step group creation: Identity → Invite. Chrome is the shared [StepFlow].
/// Creates a real Group entity (POST /groups), then sends invites, then opens
/// the group detail. There is no access step: groups are always invite-only.
class CreateGroupFlowScreen extends ConsumerStatefulWidget {
  const CreateGroupFlowScreen({super.key});

  @override
  ConsumerState<CreateGroupFlowScreen> createState() =>
      _CreateGroupFlowScreenState();
}

class _CreateGroupFlowScreenState extends ConsumerState<CreateGroupFlowScreen> {
  int _step = 0;

  final _name = TextEditingController();
  final _description = TextEditingController();

  final Set<String> _invitees = {};
  String _inviteQuery = '';

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  bool get _identityValid => _name.text.trim().isNotEmpty;

  bool get _isLastStep => _step == 1;

  String get _nextLabel => _isLastStep ? Strings.groupsCreateCta : Strings.groupsNext;

  VoidCallback? get _onNext {
    if (_submitting) return null;
    if (_step == 0 && !_identityValid) return null;
    return _advance;
  }

  void _advance() {
    if (_isLastStep) {
      _submit();
    } else {
      setState(() => _step++);
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final repo = ref.read(groupsRepositoryProvider);
      final group = await repo.createGroup(
        name: _name.text.trim(),
        description: _description.text.trim(),
      );
      // Send invites (best-effort — a failed invite doesn't undo the group).
      for (final id in _invitees) {
        try {
          await repo.inviteUser(group.id, id);
        } catch (_) {}
      }
      ref.invalidate(myGroupsProvider);
      if (!mounted) return;
      // Leave the full-screen flow, then open the new group inside the Groups
      // tab. The detail is a branch route, so it has to be pushed from the
      // shell — pushing it from this root-level page collides page keys.
      final router = GoRouter.of(context);
      router.pop();
      router.push(AppRoutes.group(group.id));
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.groupsCreate)),
      body: StepFlow(
        currentStep: _step,
        stepTitles: const [
          Strings.groupsStepIdentity,
          Strings.groupsStepInvite,
        ],
        onBack: _step == 0 ? null : () => setState(() => _step--),
        onNext: _onNext,
        nextLabel: _nextLabel,
        loading: _submitting,
        child: _stepBody(),
      ),
    );
  }

  Widget _stepBody() => _step == 0 ? _identityStep() : _inviteStep();

  // ---- Step 1: Identity --------------------------------------------------
  Widget _identityStep() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenHorizontal),
      children: [
        Center(
          child: DoctorAvatar(
            initials: _name.text.trim().isEmpty
                ? '?'
                : initialsOf(_name.text.trim()),
            colorIndex: _name.text.hashCode.abs(),
            size: AvatarSize.xxl,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppTextField(
          controller: _name,
          label: Strings.groupsNameLabel,
          hint: Strings.groupNameHint,
        ),
        const SizedBox(height: AppSpacing.lg),
        AppTextField(
          controller: _description,
          label: Strings.groupsDescriptionLabel,
          textCapitalization: TextCapitalization.sentences,
          hint: Strings.groupsDescriptionHint,
        ),
      ],
    );
  }

  // ---- Step 2: Invite ----------------------------------------------------
  // Connections AND org colleagues — you can put a colleague in a group
  // without connecting to them first.
  Widget _inviteStep() {
    final async = ref.watch(invitablePeopleProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenHorizontal,
            0,
            AppSpacing.screenHorizontal,
            AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Strings.groupsInviteStepTitle, style: AppText.subheading),
              const SizedBox(height: AppSpacing.xs),
              Text(Strings.groupsInviteStepBody, style: AppText.caption),
            ],
          ),
        ),
        AppSearchBar(
          hint: Strings.groupsInviteSearchHint,
          onChanged: (q) => setState(() => _inviteQuery = q),
        ),
        Expanded(
          child: async.when(
            loading: () => const SkeletonList(),
            error: (e, _) => Center(
              child: Text(ErrorMessages.forApi(e), style: AppText.caption),
            ),
            data: (people) {
              final q = _inviteQuery.trim().toLowerCase();
              final list = q.isEmpty
                  ? people
                  : people
                      .where((p) =>
                          p.fullName.toLowerCase().contains(q) ||
                          (p.specialty?.toLowerCase().contains(q) ?? false))
                      .toList();
              if (list.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Text(
                      q.isEmpty
                          ? Strings.groupsNoInvitablePeople
                          : Strings.netEmptySearch,
                      style: AppText.body,
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final c = list[i];
                  final selected = _invitees.contains(c.id);
                  return _InviteRow(
                    person: c,
                    selected: selected,
                    onTap: () => setState(() {
                      if (selected) {
                        _invitees.remove(c.id);
                      } else {
                        _invitees.add(c.id);
                      }
                    }),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _InviteRow extends StatelessWidget {
  final PersonCard person;
  final bool selected;
  final VoidCallback onTap;
  const _InviteRow({
    required this.person,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MemberRow(
      selected: selected,
      avatar: DoctorAvatar(
        initials: person.initials,
        colorIndex: person.avatarIndex,
        imageUrl: userAvatarUrl(person.id, person.avatarUrl),
        isSelected: selected,
      ),
      title: person.fullName,
      subtitle: person.specialty ?? person.headline,
      trailing: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected ? AppColors.medBlue : AppColors.gray400,
      ),
      onTap: onTap,
    );
  }
}
