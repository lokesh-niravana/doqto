import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'reactions.dart';

/// What a long-press on a bubble can do (batch 4). The thread decides which
/// apply to the message; the sheet only lays them out.
enum MessageAction {
  reply,
  forward,
  copy,
  star,
  unstar,
  pin,
  unpin,
  info,
  edit,
  delete,
  report,
  select;

  String get label => switch (this) {
        MessageAction.reply => Strings.chatReply,
        MessageAction.forward => Strings.chatForward,
        MessageAction.copy => Strings.chatCopy,
        MessageAction.star => Strings.chatStar,
        MessageAction.unstar => Strings.chatUnstar,
        MessageAction.pin => Strings.chatPinMessage,
        MessageAction.unpin => Strings.chatUnpinMessage,
        MessageAction.info => Strings.chatInfo,
        MessageAction.edit => Strings.chatEdit,
        MessageAction.delete => Strings.chatDelete,
        MessageAction.report => Strings.chatReport,
        MessageAction.select => Strings.chatSelect,
      };

  IconData get icon => switch (this) {
        MessageAction.reply => Icons.reply_rounded,
        MessageAction.forward => Icons.shortcut_rounded,
        MessageAction.copy => Icons.copy_rounded,
        MessageAction.star => Icons.star_border_rounded,
        MessageAction.unstar => Icons.star_rounded,
        MessageAction.pin => Icons.push_pin_outlined,
        MessageAction.unpin => Icons.push_pin_rounded,
        MessageAction.info => Icons.info_outline_rounded,
        MessageAction.edit => Icons.edit_outlined,
        MessageAction.delete => Icons.delete_outline_rounded,
        MessageAction.report => Icons.flag_outlined,
        MessageAction.select => Icons.check_circle_outline_rounded,
      };

  bool get destructive => this == MessageAction.delete || this == MessageAction.report;
}

/// Result of the sheet: a menu action, a reaction pick (emoji, or null for
/// "more"), or nothing (dismissed).
sealed class ContextMenuResult {
  const ContextMenuResult();
}

class ContextMenuAction extends ContextMenuResult {
  final MessageAction action;
  const ContextMenuAction(this.action);
}

class ContextMenuReaction extends ContextMenuResult {
  /// null = the "+" button (open the full picker).
  final String? emoji;
  const ContextMenuReaction(this.emoji);
}

/// Long-press sheet: the reaction tray on top (when [reactable]), then one
/// row per [actions]. Keys: `ctx-<action name>` and the tray's own keys.
Future<ContextMenuResult?> showMessageContextMenu(
  BuildContext context, {
  required List<MessageAction> actions,
  required bool reactable,
  String? currentReaction,
}) {
  return showModalBottomSheet<ContextMenuResult>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          key: const ValueKey('message-context-menu'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reactable)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: ReactionTray(
                    current: currentReaction,
                    onPick: (e) => Navigator.of(ctx).pop(ContextMenuReaction(e)),
                    onMore: () => Navigator.of(ctx).pop(const ContextMenuReaction(null)),
                  ),
                ),
              ),
            if (reactable) const Divider(height: 1),
            for (final a in actions)
              ListTile(
                key: ValueKey('ctx-${a.name}'),
                dense: true,
                leading: Icon(
                  a.icon,
                  color: a.destructive ? AppColors.red : AppColors.medBlue,
                  size: 22,
                ),
                title: Text(
                  a.label,
                  style: AppText.bodyPrimary.copyWith(
                    color: a.destructive ? AppColors.red : null,
                  ),
                ),
                onTap: () => Navigator.of(ctx).pop(ContextMenuAction(a)),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    ),
  );
}
