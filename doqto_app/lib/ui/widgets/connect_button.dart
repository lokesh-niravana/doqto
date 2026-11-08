import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/strings.dart';
import '../../core/enums/app_enums.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/utils/error_messages.dart';
import '../../state/network_state.dart';
import 'primary_button.dart';
import 'stateful_action_button.dart';

/// Typed control over a person's [RelationshipState], driven by
/// `relationshipProvider(userId)`:
///   - none            → Connect          (optimistic → pending)
///                       …or Message for a same-org colleague, who never
///                       needs a connection to talk to you
///   - pending_outgoing→ Pending          (long-press / tap → withdraw)
///   - pending_incoming→ Accept + Ignore  (paired)
///   - connected       → Message          (calls [onMessage])
class ConnectButton extends ConsumerWidget {
  final String userId;
  final VoidCallback? onMessage;
  final bool expand;

  const ConnectButton({
    super.key,
    required this.userId,
    this.onMessage,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rel =
        ref.watch(relationshipProvider(userId)).valueOrNull?.relationship;
    if (rel == null) return const SizedBox.shrink();
    final notifier = ref.read(relationshipProvider(userId).notifier);

    switch (rel.connectionState) {
      case RelationshipState.none:
        // Same-org colleagues can be messaged without connecting first, so
        // messaging IS the action. Not keyed off can_message: an org with
        // dm_policy 'everyone' is open too, and there Connect still means
        // something.
        if (rel.isColleague) {
          return AppButton(
            label: Strings.netMessage,
            icon: Icons.chat_bubble_outline,
            expand: expand,
            onPressed: onMessage,
          );
        }
        return StatefulActionButton<RelationshipState>(
          state: RelationshipState.none,
          expand: expand,
          optimisticNext: (_) => RelationshipState.pendingOutgoing,
          onPressed: notifier.invite,
          visuals: const {
            RelationshipState.none: ActionVisual(
              label: Strings.netConnect,
              icon: Icons.person_add_alt_1,
            ),
            RelationshipState.pendingOutgoing: ActionVisual(
              label: Strings.netPending,
              variant: AppButtonVariant.secondary,
            ),
          },
        );

      case RelationshipState.pendingOutgoing:
        return AppButton(
          label: Strings.netPending,
          icon: Icons.schedule,
          variant: AppButtonVariant.secondary,
          expand: expand,
          onPressed: () => _confirmWithdraw(context, notifier),
        );

      case RelationshipState.pendingIncoming:
        return Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Expanded(
              flex: expand ? 1 : 0,
              child: StatefulActionButton<RelationshipState>(
                state: RelationshipState.pendingIncoming,
                expand: expand,
                optimisticNext: (_) => RelationshipState.connected,
                onPressed: notifier.accept,
                visuals: const {
                  RelationshipState.pendingIncoming:
                      ActionVisual(label: Strings.netAccept),
                  RelationshipState.connected:
                      ActionVisual(label: Strings.netConnected),
                },
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              flex: expand ? 1 : 0,
              child: StatefulActionButton<RelationshipState>(
                state: RelationshipState.pendingIncoming,
                expand: expand,
                optimisticNext: (_) => RelationshipState.none,
                onPressed: notifier.ignore,
                visuals: const {
                  RelationshipState.pendingIncoming: ActionVisual(
                    label: Strings.netIgnore,
                    variant: AppButtonVariant.ghost,
                  ),
                  RelationshipState.none: ActionVisual(
                    label: Strings.netIgnore,
                    variant: AppButtonVariant.ghost,
                  ),
                },
              ),
            ),
          ],
        );

      case RelationshipState.connected:
        return AppButton(
          label: Strings.netMessage,
          icon: Icons.chat_bubble_outline,
          variant: AppButtonVariant.secondary,
          expand: expand,
          onPressed: onMessage,
        );

      case RelationshipState.blocked:
        // The profile screen renders the Unblock affordance itself.
        return const SizedBox.shrink();
    }
  }

  Future<void> _confirmWithdraw(
    BuildContext context,
    RelationshipNotifier notifier,
  ) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(Strings.netWithdrawConfirm),
            ),
            ListTile(
              leading: const Icon(Icons.undo, color: AppColors.red),
              title: const Text(Strings.netWithdraw),
              onTap: () => Navigator.of(ctx).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text(Strings.cancel),
              onTap: () => Navigator.of(ctx).pop(false),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    try {
      await notifier.withdraw();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(Strings.netInviteWithdrawnToast)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMessages.forApi(e)),
            backgroundColor: AppColors.red,
          ),
        );
      }
    }
  }
}
