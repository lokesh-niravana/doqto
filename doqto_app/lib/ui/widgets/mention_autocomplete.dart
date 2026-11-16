import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/shadows.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../data/models/group.dart';
import 'doctor_avatar.dart';
import '../../core/utils/avatar_urls.dart';

/// The @mention suggestions above a group composer (batch 4): members whose
/// name contains the typed query, me excluded. Keys: `mention-<userId>`.
class MentionAutocomplete extends StatelessWidget {
  final List<GroupMember> members;
  final String query;
  final String? meId;
  final ValueChanged<GroupMember> onPick;

  const MentionAutocomplete({
    super.key,
    required this.members,
    required this.query,
    required this.meId,
    required this.onPick,
  });

  List<GroupMember> get matches {
    final q = query.trim().toLowerCase();
    return [
      for (final m in members)
        if (m.userId != meId && (q.isEmpty || m.fullName.toLowerCase().contains(q))) m,
    ].take(6).toList();
  }

  @override
  Widget build(BuildContext context) {
    final rows = matches;
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('mention-autocomplete'),
      margin: const EdgeInsets.fromLTRB(AppSpacing.sm, 0, AppSpacing.sm, AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
            child: Row(
              children: [Text(Strings.chatMentionHint.toUpperCase(), style: AppText.label)],
            ),
          ),
          for (final m in rows)
            ListTile(
              key: ValueKey('mention-${m.userId}'),
              dense: true,
              leading: DoctorAvatar(
                initials: m.initials,
                colorIndex: m.avatarIndex,
                size: AvatarSize.sm,
                imageUrl: userAvatarUrl(m.userId, m.avatarUrl),
              ),
              title: Text(m.fullName, style: AppText.bodyPrimary),
              subtitle: m.specialty == null ? null : Text(m.specialty!, style: AppText.caption),
              onTap: () => onPick(m),
            ),
        ],
      ),
    );
  }
}
