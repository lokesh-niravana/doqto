import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/shadows.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../data/models/message.dart';
import 'doctor_avatar.dart';

/// WhatsApp's six. Anything else comes from the "+" picker.
const kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Spoken names for the quick set (screen readers read raw emoji poorly).
const _quickNames = {
  '👍': 'thumbs up',
  '❤️': 'red heart',
  '😂': 'face with tears of joy',
  '😮': 'face with open mouth',
  '😢': 'crying face',
  '🙏': 'folded hands',
};

String reactionSpokenName(String emoji) => _quickNames[emoji] ?? emoji;

/// The pill above a selected bubble: six quick reactions + "+". My current
/// reaction is circled; if it isn't one of the six it takes the "+" slot
/// (still circled) and "+" moves after it.
class ReactionTray extends StatelessWidget {
  final String? current;
  final ValueChanged<String> onPick;
  final VoidCallback onMore;

  const ReactionTray({
    super.key,
    required this.current,
    required this.onPick,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final custom = current != null && !kQuickReactions.contains(current);
    return Material(
      key: const ValueKey('reaction-tray'),
      color: AppColors.white,
      elevation: 0,
      shape: const StadiumBorder(),
      child: DecoratedBox(
        decoration: const ShapeDecoration(
          shape: StadiumBorder(),
          shadows: AppShadows.elevated,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in kQuickReactions)
                _TrayButton(emoji: e, selected: current == e, onTap: () => onPick(e)),
              if (custom)
                _TrayButton(emoji: current!, selected: true, onTap: () => onPick(current!)),
              Semantics(
                button: true,
                label: 'More reactions',
                child: InkResponse(
                  key: const ValueKey('reaction-more'),
                  onTap: onMore,
                  radius: 22,
                  child: const SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(Icons.add_circle_outline, color: AppColors.gray600, size: 26),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrayButton extends StatelessWidget {
  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  const _TrayButton({required this.emoji, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: reactionSpokenName(emoji),
      child: InkResponse(
        key: ValueKey('reaction-pick-$emoji'),
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        radius: 22,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: AnimatedContainer(
              duration: AppMotion.maybe(context, AppMotion.micro),
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.gray200 : Colors.transparent,
              ),
              child: ExcludeSemantics(
                child: Text(emoji, style: const TextStyle(fontSize: 26, height: 1.1)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small pill hanging off a bubble: up to three emoji (most used
/// first) and the total when it's over one. Outlined when I reacted.
class ReactionPills extends StatelessWidget {
  final List<MessageReaction> reactions;
  final String? me;
  final VoidCallback? onTap;

  const ReactionPills({super.key, required this.reactions, required this.me, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final total = reactions.fold<int>(0, (n, r) => n + r.count);
    final mine = me != null && reactions.any((r) => r.userIds.contains(me));
    final spoken = [
      for (final r in reactions) '${r.count} ${reactionSpokenName(r.emoji)}',
    ].join(', ');
    return Semantics(
      button: onTap != null,
      label: 'Reactions: $spoken. Double tap to see who reacted.',
      child: GestureDetector(
        key: const ValueKey('reaction-pills'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          // Comfortable touch target without inflating the pill itself.
          constraints: const BoxConstraints(minHeight: 32, minWidth: 44),
          child: Center(
            widthFactor: 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(AppRadii.full),
                border: Border.all(
                  color: mine ? AppColors.medBlue : AppColors.gray200,
                  width: mine ? 1.5 : 1,
                ),
                boxShadow: AppShadows.card,
              ),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      reactions.take(3).map((r) => r.emoji).join(),
                      style: const TextStyle(fontSize: 15, height: 1.2),
                    ),
                    if (total > 1) ...[
                      const SizedBox(width: 3),
                      Text(
                        '$total',
                        key: const ValueKey('reaction-total'),
                        style: AppText.timestamp.copyWith(color: AppColors.gray600),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Who-reacted bottom sheet: "All N" + a tab per emoji; my row first as
/// "You · Tap to remove". [nameFor] resolves names from members the thread
/// already holds.
Future<void> showWhoReactedSheet({
  required BuildContext context,
  required List<MessageReaction> reactions,
  required String? me,
  required String Function(String userId) nameFor,
  required int Function(String userId) colorFor,
  required VoidCallback onRemoveMine,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => _WhoReactedSheet(
      reactions: reactions,
      me: me,
      nameFor: nameFor,
      colorFor: colorFor,
      onRemoveMine: () {
        Navigator.pop(ctx);
        onRemoveMine();
      },
    ),
  );
}

class _WhoReactedSheet extends StatelessWidget {
  final List<MessageReaction> reactions;
  final String? me;
  final String Function(String) nameFor;
  final int Function(String) colorFor;
  final VoidCallback onRemoveMine;

  const _WhoReactedSheet({
    required this.reactions,
    required this.me,
    required this.nameFor,
    required this.colorFor,
    required this.onRemoveMine,
  });

  List<(String, String)> _rows(String? only) {
    final rows = <(String, String)>[
      for (final r in reactions)
        if (only == null || r.emoji == only)
          for (final u in r.userIds) (u, r.emoji),
    ];
    // Mine first, the rest in server order.
    rows.sort((a, b) => (a.$1 == me ? 0 : 1).compareTo(b.$1 == me ? 0 : 1));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final total = reactions.fold<int>(0, (n, r) => n + r.count);
    final tabs = <String?>[null, for (final r in reactions) r.emoji];
    return DefaultTabController(
      length: tabs.length,
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.45,
          child: Column(
            children: [
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: AppColors.medBlue,
                unselectedLabelColor: AppColors.gray600,
                indicatorColor: AppColors.medBlue,
                tabs: [
                  for (final t in tabs)
                    Tab(
                      text: t == null
                          ? 'All $total'
                          : '$t ${reactions.firstWhere((r) => r.emoji == t).count}',
                    ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    for (final t in tabs)
                      ListView(
                        children: [
                          for (final (uid, emoji) in _rows(t))
                            _row(uid, emoji),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String uid, String emoji) {
    final isMe = uid == me;
    final name = isMe ? 'You' : nameFor(uid);
    final initials = name
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p.characters.first.toUpperCase())
        .join();
    return ListTile(
      key: ValueKey('who-reacted-$uid'),
      leading: DoctorAvatar(
        initials: initials.isEmpty ? '?' : initials,
        colorIndex: colorFor(uid),
        size: AvatarSize.sm,
      ),
      title: Text(name, style: AppText.bodyPrimary),
      subtitle: isMe ? Text('Tap to remove', style: AppText.caption) : null,
      trailing: Text(emoji, style: const TextStyle(fontSize: 22)),
      onTap: isMe ? onRemoveMine : null,
    );
  }
}
