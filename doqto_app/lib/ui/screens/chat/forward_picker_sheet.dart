import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/strings.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/models/conversation.dart';
import '../../../data/models/network_profile.dart';
import '../../../state/auth_state.dart';
import '../../../state/chat_state.dart';
import '../../../state/network_state.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/search_bar.dart';
import '../../../core/utils/avatar_urls.dart';

/// Where a forward goes: an existing chat, or a connection without one yet
/// (the caller opens the direct chat first — the server hands back an
/// existing one when there is).
class ForwardTarget {
  final String? conversationId;
  final String? userId;
  final String name;
  const ForwardTarget({this.conversationId, this.userId, required this.name});

  String get key => conversationId ?? 'user:$userId';
}

/// The forward picker (batch 4): recent chats first, then people you can
/// message, multi-select up to [max]. Returns the picks or null.
Future<List<ForwardTarget>?> showForwardPicker(
  BuildContext context, {
  required String excludeConversationId,
}) {
  return showModalBottomSheet<List<ForwardTarget>>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ForwardPickerSheet(excludeConversationId: excludeConversationId),
  );
}

class ForwardPickerSheet extends ConsumerStatefulWidget {
  final String excludeConversationId;
  static const int max = 5;

  const ForwardPickerSheet({super.key, required this.excludeConversationId});

  @override
  ConsumerState<ForwardPickerSheet> createState() => _ForwardPickerSheetState();
}

class _ForwardPickerSheetState extends ConsumerState<ForwardPickerSheet> {
  String _query = '';
  final _picked = <String, ForwardTarget>{};

  void _toggle(ForwardTarget t) {
    setState(() {
      if (_picked.containsKey(t.key)) {
        _picked.remove(t.key);
      } else if (_picked.length < ForwardPickerSheet.max) {
        _picked[t.key] = t;
      } else {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text(Strings.chatForwardLimit)),
        );
      }
    });
  }

  bool _match(String s) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty || s.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final meId = ref.watch(authProvider).user?.id;
    final convs = ref.watch(conversationsProvider).asData?.value ?? const <Conversation>[];
    final people = ref.watch(connectionsProvider).asData?.value ?? const <PersonCard>[];

    final recent = [
      for (final c in convs)
        if (c.id != widget.excludeConversationId && !c.prefs.archived && c.access != ConversationAccess.pendingRequest)
          c,
    ]..sort((a, b) => (b.lastMessageAt ?? b.updatedAt).compareTo(a.lastMessageAt ?? a.updatedAt));
    final withChat = <String>{
      for (final c in recent)
        if (c.type == ConversationType.direct)
          for (final id in c.memberIds)
            if (id != meId) id,
    };
    final others = [
      for (final p in people)
        if (!withChat.contains(p.id) && p.id != meId) p,
    ];

    String titleOf(Conversation c) => c.type == ConversationType.group
        ? (c.name ?? 'Group')
        : (c.displayName ?? 'Direct chat');

    final shownRecent = recent.where((c) => _match(titleOf(c))).toList();
    final shownOthers = others.where((p) => _match(p.fullName)).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          key: const ValueKey('forward-picker'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, 0),
              child: Row(
                children: [
                  Expanded(child: Text(Strings.chatForwardTitle, style: AppText.heading)),
                  Text(
                    '${_picked.length}/${ForwardPickerSheet.max}',
                    key: const ValueKey('forward-count'),
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            AppSearchBar(hint: Strings.chatForwardHint, onChanged: (q) => setState(() => _query = q)),
            Expanded(
              child: ListView(
                children: [
                  if (shownRecent.isNotEmpty) const _Header('RECENT CHATS'),
                  for (final c in shownRecent)
                    _row(
                      ForwardTarget(conversationId: c.id, name: titleOf(c)),
                      initials: _initials(titleOf(c)),
                      subtitle: c.type == ConversationType.group ? 'Group' : null,
                      colorSeed: c.id,
                      isGroup: c.type == ConversationType.group,
                    ),
                  if (shownOthers.isNotEmpty) const _Header('PEOPLE'),
                  for (final p in shownOthers)
                    _row(
                      ForwardTarget(userId: p.id, name: p.fullName),
                      initials: p.initials,
                      subtitle: p.specialty,
                      colorSeed: p.id,
                      image: userAvatarUrl(p.id, p.avatarUrl),
                    ),
                  if (shownRecent.isEmpty && shownOthers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text('No chats match.', style: AppText.caption, textAlign: TextAlign.center),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: AppButton(
                  key: const ValueKey('forward-confirm'),
                  label: _picked.isEmpty
                      ? Strings.chatForward
                      : '${Strings.chatForward} · ${_picked.values.map((t) => t.name.split(' ').first).join(', ')}',
                  expand: true,
                  icon: Icons.shortcut_rounded,
                  onPressed: _picked.isEmpty ? null : () => Navigator.of(context).pop(_picked.values.toList()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
  }

  Widget _row(
    ForwardTarget t, {
    required String initials,
    required String colorSeed,
    String? subtitle,
    String? image,
    bool isGroup = false,
  }) {
    final selected = _picked.containsKey(t.key);
    return ListTile(
      key: ValueKey('forward-target-${t.key}'),
      leading: isGroup
          ? CircleAvatar(
              backgroundColor: AppColors.medBlueLight,
              foregroundColor: AppColors.medBlue,
              child: const Icon(Icons.group_outlined),
            )
          : DoctorAvatar(initials: initials, colorIndex: colorSeed.hashCode, imageUrl: image, size: AvatarSize.md),
      title: Text(t.name, style: AppText.bodyPrimary, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null || subtitle.isEmpty ? null : Text(subtitle, style: AppText.caption),
      trailing: Icon(
        selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
        color: selected ? AppColors.medBlue : AppColors.gray400,
      ),
      onTap: () => _toggle(t),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xs),
        child: Text(text, style: AppText.label),
      );
}
