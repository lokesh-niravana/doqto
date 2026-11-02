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
import '../../../data/models/network_profile.dart';
import '../../../state/network_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/person_card_row.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/search_bar.dart';

/// The full connections list with a client-side name filter (v1). Tap → profile;
/// long-press → an action sheet (Message / View profile / Remove / Block).
class ConnectionsScreen extends ConsumerStatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  ConsumerState<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends ConsumerState<ConnectionsScreen> {
  String _query = '';

  bool _match(PersonCard p) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return p.fullName.toLowerCase().contains(q) ||
        (p.headline?.toLowerCase().contains(q) ?? false) ||
        (p.specialty?.toLowerCase().contains(q) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(connectionsProvider);
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.netConnections)),
      body: Column(
        children: [
          AppSearchBar(
            hint: Strings.netSearchConnectionsHint,
            onChanged: (q) => setState(() => _query = q),
          ),
          Expanded(
            child: async.when(
              skipLoadingOnReload: true,
              skipLoadingOnRefresh: true,
              loading: () => const SkeletonList(),
              error: (e, _) => _ErrorPane(
                message: ErrorMessages.forApi(e),
                onRetry: () => ref.invalidate(connectionsProvider),
              ),
              data: (all) {
                final list = all.where(_match).toList();
                if (list.isEmpty) {
                  return _EmptyPane(
                    text: _query.isEmpty
                        ? Strings.netEmptyConnections
                        : Strings.netEmptySearch,
                  );
                }
                return RefreshIndicator(
                  onRefresh: () =>
                      ref.read(connectionsProvider.notifier).refresh(),
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(
                      top: AppSpacing.sm,
                      bottom: MediaQuery.paddingOf(context).bottom +
                          AppSpacing.xl,
                    ),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final p = list[i];
                      return FadeSlideIn.staggered(
                        i,
                        PersonCardRow(
                          person: p,
                          onTap: () => context.push(AppRoutes.person(p.id)),
                          onLongPress: () => _openSheet(context, p),
                          trailing: IconButton(
                            tooltip: Strings.netMessage,
                            icon: const Icon(Icons.chat_bubble_outline),
                            color: AppColors.medBlue,
                            onPressed: () => _startChat(p),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startChat(PersonCard p) async {
    try {
      final conv = await ref.read(chatRepositoryProvider).createConversation(
            type: ConversationType.direct,
            name: null,
            memberIds: [p.id],
          );
      if (!mounted) return;
      openConversation(context, conv.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }

  void _openSheet(BuildContext context, PersonCard p) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text(Strings.netMessage),
              onTap: () {
                Navigator.of(ctx).pop();
                _startChat(p);
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text(Strings.netViewProfile),
              onTap: () {
                Navigator.of(ctx).pop();
                context.push(AppRoutes.person(p.id));
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.person_remove_outlined, color: AppColors.red),
              title: const Text(Strings.netRemoveConnection),
              onTap: () {
                Navigator.of(ctx).pop();
                _confirmRemove(context, p);
              },
            ),
            ListTile(
              leading: const Icon(Icons.block, color: AppColors.red),
              title: const Text(Strings.netBlock),
              onTap: () {
                Navigator.of(ctx).pop();
                _confirmBlock(context, p);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, PersonCard p) async {
    final ok = await _confirm(
      context,
      title: Strings.netRemoveConnection,
      body: Strings.netRemoveConnectionConfirm,
      confirmLabel: Strings.netRemoveConnection,
    );
    if (ok != true) return;
    try {
      await ref.read(connectionsProvider.notifier).remove(p.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(Strings.netConnectionRemovedToast)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  Future<void> _confirmBlock(BuildContext context, PersonCard p) async {
    final ok = await _confirm(
      context,
      title: Strings.netBlock,
      body: Strings.netBlockConfirm,
      confirmLabel: Strings.netBlock,
    );
    if (ok != true) return;
    try {
      await ref.read(connectionsProvider.notifier).block(p.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(Strings.netBlockedToast)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(Strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }
}

class _EmptyPane extends StatelessWidget {
  final String text;
  const _EmptyPane({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.group_outlined, size: 48, color: AppColors.gray400),
            const SizedBox(height: AppSpacing.md),
            Text(text, style: AppText.body, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorPane({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 40, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.md),
            Text(message, style: AppText.caption, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
                label: Strings.retry,
                icon: Icons.refresh_rounded,
                onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
