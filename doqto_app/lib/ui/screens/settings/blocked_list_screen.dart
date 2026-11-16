import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/network_profile.dart';
import '../../../state/network_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/person_card_row.dart';
import '../../widgets/primary_button.dart';

/// Settings → Privacy → Blocked contacts (batch 2). Unblock asks once, then
/// the row goes at once and comes back only if the server refuses.
class BlockedListScreen extends ConsumerWidget {
  const BlockedListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(blockedProvider);
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.privacyBlocked)),
      body: async.when(
        loading: () => const _Skeleton(),
        error: (e, _) => _Pane(
          icon: Icons.cloud_off_outlined,
          text: Strings.netErrorGeneric,
          action: AppButton(
            label: Strings.retry,
            variant: AppButtonVariant.secondary,
            onPressed: () => ref.invalidate(blockedProvider),
          ),
        ),
        data: (list) => list.isEmpty
            ? const _Pane(
                icon: Icons.block_outlined,
                text: Strings.privacyBlockedEmpty,
              )
            : RefreshIndicator(
                onRefresh: () => ref.read(blockedProvider.notifier).refresh(),
                child: ListView.builder(
                  key: const ValueKey('blocked-list'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final p = list[i];
                    return FadeSlideIn.staggered(
                      i,
                      PersonCardRow(
                        person: p,
                        onTap: () => context.push(AppRoutes.person(p.id)),
                        trailing: TextButton(
                          key: ValueKey('unblock-${p.id}'),
                          onPressed: () => confirmUnblock(context, ref, p),
                          child: const Text(Strings.netUnblock),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }

  /// Shared with the person profile: one dialog, one wording.
  static Future<bool> confirmUnblock(
      BuildContext context, WidgetRef ref, PersonCard person) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(Strings.privacyUnblockConfirmTitle),
        content: const Text(Strings.privacyUnblockConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(Strings.cancel),
          ),
          TextButton(
            key: const ValueKey('unblock-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(Strings.netUnblock),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;
    try {
      await ref.read(blockedProvider.notifier).unblock(person.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(Strings.privacyUnblockedToast)),
        );
      }
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ));
      }
      return false;
    }
  }
}

class _Pane extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const _Pane({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.md),
            Text(text, style: AppText.body, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
      children: [
        for (var i = 0; i < 4; i++) ...[
          AppSkeleton.block(height: 64),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}
