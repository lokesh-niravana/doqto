import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../data/models/message.dart';
import 'app_pressable.dart';
import 'attachment_bubbles.dart';
import 'doctor_avatar.dart';

/// Poll message (batch 5 I): question, options with result bars, tap to
/// vote / unvote, "View votes" when anyone has voted.
class PollBubble extends StatelessWidget {
  final Message message;
  final PollData poll;
  final bool isMine;
  final String? me;
  final void Function(List<String> optionIds)? onVote;
  final VoidCallback? onViewVotes;

  const PollBubble({
    super.key,
    required this.message,
    required this.poll,
    required this.isMine,
    required this.me,
    this.onVote,
    this.onViewVotes,
  });

  void _tap(PollOption o) {
    final mine = (me == null ? const <String>[] : poll.myOptionIds(me!)).toSet();
    if (poll.multiple) {
      if (mine.contains(o.id)) {
        mine.remove(o.id);
      } else {
        mine.add(o.id);
      }
      onVote?.call(mine.toList());
    } else {
      onVote?.call(mine.contains(o.id) ? const [] : [o.id]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contrast = isMine ? AppColors.white : AppColors.textPrimary;
    final sub = isMine ? AppColors.white.withValues(alpha: 0.75) : AppColors.textMuted;
    final total = poll.voterCount;
    final maxVotes = poll.options.fold<int>(0, (a, o) => o.voteCount > a ? o.voteCount : a);
    final mine = (me == null ? const <String>[] : poll.myOptionIds(me!)).toSet();
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
      decoration: BoxDecoration(
        color: isMine ? AppColors.medBlue : AppColors.white,
        borderRadius: isMine ? AppRadii.bubbleSent : AppRadii.bubbleReceived,
        border: isMine ? null : Border.all(color: AppColors.gray100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.poll_outlined, size: 18, color: contrast),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  poll.question,
                  key: const ValueKey('poll-question-text'),
                  style: AppText.bodyPrimary.copyWith(color: contrast, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(poll.multiple ? Strings.pollSelectMany : Strings.pollSelectOne, style: AppText.timestamp.copyWith(color: sub)),
          const SizedBox(height: AppSpacing.sm),
          for (final o in poll.options)
            _PollOptionRow(
              key: ValueKey('poll-opt-${o.id}'),
              option: o,
              selected: mine.contains(o.id),
              fraction: maxVotes == 0 ? 0 : o.voteCount / maxVotes,
              percent: total == 0 ? 0 : (o.voteCount * 100 / total).round(),
              contrast: contrast,
              sub: sub,
              isMine: isMine,
              onTap: onVote == null ? null : () => _tap(o),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  total == 0 ? Strings.pollNoVotes : '$total ${total == 1 ? Strings.pollVote : Strings.pollVotes}',
                  key: const ValueKey('poll-total'),
                  style: AppText.timestamp.copyWith(color: sub),
                ),
              ),
              BubbleFooter(
                isMine: isMine,
                timestamp: message.createdAt.toLocal(),
                read: message.read,
                delivered: message.delivered,
                status: message.status,
              ),
            ],
          ),
          if (total > 0 && onViewVotes != null)
            Center(
              child: AppPressable(
                key: const ValueKey('poll-view-votes'),
                onTap: onViewVotes,
                minTarget: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: Text(Strings.pollViewVotes, style: AppText.label.copyWith(color: isMine ? AppColors.white : AppColors.medBlue)),
                ),
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [bubble],
      ),
    );
  }
}

class _PollOptionRow extends StatelessWidget {
  final PollOption option;
  final bool selected;
  final double fraction;
  final int percent;
  final Color contrast;
  final Color sub;
  final bool isMine;
  final VoidCallback? onTap;
  const _PollOptionRow({
    super.key,
    required this.option,
    required this.selected,
    required this.fraction,
    required this.percent,
    required this.contrast,
    required this.sub,
    required this.isMine,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final barColor = isMine ? AppColors.white : AppColors.medBlue;
    return AppPressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  key: ValueKey(selected ? 'poll-selected' : 'poll-unselected'),
                  size: 20,
                  color: selected ? barColor : sub,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(option.text, style: AppText.messageBody.copyWith(color: contrast))),
                const SizedBox(width: AppSpacing.sm),
                Text('${option.voteCount}', key: ValueKey('poll-count-${option.id}'), style: AppText.caption.copyWith(color: sub)),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: ClipRRect(
                borderRadius: AppRadii.rFull,
                child: Stack(
                  children: [
                    Container(height: 5, color: barColor.withValues(alpha: 0.2)),
                    AnimatedFractionallySizedBox(
                      duration: AppMotion.maybe(context, AppMotion.base),
                      curve: AppMotion.standard,
                      widthFactor: fraction.clamp(0.0, 1.0),
                      child: Container(height: 5, color: barColor),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Who voted for what (batch 5 I).
Future<void> showPollVotersSheet({
  required BuildContext context,
  required PollData poll,
  required String Function(String userId) nameFor,
  required int Function(String userId) colorFor,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
        child: ListView(
          key: const ValueKey('poll-voters-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.lg),
          children: [
            Text(poll.question, style: AppText.heading),
            const SizedBox(height: AppSpacing.sm),
            for (final o in poll.options) ...[
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.xs),
                child: Row(
                  children: [
                    Expanded(child: Text(o.text, style: AppText.label)),
                    Text('${o.voteCount}', style: AppText.caption),
                  ],
                ),
              ),
              if (o.voterIds.isEmpty)
                Text(Strings.pollNoVotes, style: AppText.caption)
              else
                for (final uid in o.voterIds)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Row(
                      children: [
                        DoctorAvatar(initials: _initials(nameFor(uid)), colorIndex: colorFor(uid), size: AvatarSize.sm),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(child: Text(nameFor(uid), style: AppText.bodyPrimary)),
                      ],
                    ),
                  ),
            ],
          ],
        ),
      ),
    ),
  );
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}
