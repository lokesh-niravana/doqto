import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/strings.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/group.dart';
import '../../../state/auth_state.dart';
import '../../../state/groups_state.dart';
import '../../../state/network_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/member_row.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/search_bar.dart';

/// Who an owner/admin can add: my connections, then org colleagues (the same
/// pool as New message), minus people already in the group. Multi-select,
/// then one Invite that sends a direct invite to each.
Future<void> showGroupAddMembersSheet(
  BuildContext context, {
  required Group group,
  required Set<String> existing,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _AddMembersSheet(group: group, existing: existing),
  );
}

typedef _Person = ({String id, String name, String sub, String initials, int color, String? image});

class _AddMembersSheet extends ConsumerStatefulWidget {
  final Group group;
  final Set<String> existing;
  const _AddMembersSheet({required this.group, required this.existing});

  @override
  ConsumerState<_AddMembersSheet> createState() => _AddMembersSheetState();
}

class _AddMembersSheetState extends ConsumerState<_AddMembersSheet> {
  String _query = '';
  final _picked = <String>{};
  bool _sending = false;

  bool _match(_Person p) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty ||
        p.name.toLowerCase().contains(q) ||
        p.sub.toLowerCase().contains(q);
  }

  Future<void> _invite() async {
    if (_picked.isEmpty || _sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(groupDetailProvider(widget.group.id).notifier);
    var sent = 0;
    Object? firstError;
    for (final id in _picked) {
      try {
        await notifier.invite(id);
        sent++;
      } catch (e) {
        firstError ??= e;
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    if (sent > 0) {
      messenger.showSnackBar(SnackBar(
        content: Text(sent == 1 ? Strings.groupInviteSent : Strings.groupInvitesSent(sent)),
      ));
    }
    if (firstError != null) {
      messenger.showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(firstError)),
        backgroundColor: AppColors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final meId = ref.watch(authProvider).user?.id;
    final org = ref.watch(orgProvider).current;
    final connectionsAsync = ref.watch(connectionsProvider);
    final membersAsync = org == null ? null : ref.watch(orgMembersProvider(org.id));
    final skip = {...widget.existing, ?meId};

    final people = <_Person>[
      for (final c in connectionsAsync.value ?? const [])
        if (!skip.contains(c.id))
          (
            id: c.id,
            name: c.fullName,
            sub: c.specialty ?? '',
            initials: c.initials,
            color: c.avatarIndex,
            image: c.avatarPresignedUrl,
          ),
    ];
    final seen = {for (final p in people) p.id};
    for (final m in membersAsync?.value ?? const []) {
      if (skip.contains(m.id) || seen.contains(m.id)) continue;
      people.add((
        id: m.id,
        name: m.fullName,
        sub: m.specialty ?? '',
        initials: m.initials,
        color: m.avatarIndex,
        image: m.avatarPresignedUrl,
      ));
    }
    final shown = people.where(_match).toList();
    final loading = connectionsAsync.isLoading && !connectionsAsync.hasValue;

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(Strings.groupAddMembersTitle, style: AppText.heading),
                ),
                if (_picked.isNotEmpty)
                  Text('${_picked.length} ${Strings.groupSelected.toLowerCase()}',
                      style: AppText.caption),
              ],
            ),
          ),
          AppSearchBar(
            key: const ValueKey('add-members-search'),
            hint: 'Search name or specialty',
            onChanged: (q) => setState(() => _query = q),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : people.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.xl),
                          child: Text(Strings.groupNoOneToAdd,
                              style: AppText.body, textAlign: TextAlign.center),
                        ),
                      )
                    : ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final p = shown[i];
                          final on = _picked.contains(p.id);
                          return MemberRow(
                            key: ValueKey('add-${p.id}'),
                            avatar: DoctorAvatar(
                              initials: p.initials,
                              colorIndex: p.color,
                              imageUrl: p.image,
                              isSelected: on,
                            ),
                            title: p.name,
                            subtitle: p.sub.isEmpty ? null : p.sub,
                            selected: on,
                            trailing: Icon(
                              on ? Icons.check_circle : Icons.circle_outlined,
                              color: on ? AppColors.medBlue : AppColors.gray400,
                            ),
                            onTap: () => setState(
                              () => on ? _picked.remove(p.id) : _picked.add(p.id),
                            ),
                          );
                        },
                      ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: AppButton(
              key: const ValueKey('add-members-invite'),
              label: _picked.isEmpty
                  ? Strings.groupAddMembersTitle
                  : '${Strings.groupAddMembersTitle} (${_picked.length})',
              expand: true,
              loading: _sending,
              onPressed: _picked.isEmpty || _sending ? null : _invite,
            ),
          ),
        ],
      ),
    );
  }
}
