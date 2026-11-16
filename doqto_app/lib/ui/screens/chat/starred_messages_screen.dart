import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../core/utils/rich_text.dart';
import '../../../data/models/message.dart';
import '../../../state/auth_state.dart';
import '../../../state/chat_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/swipe_action_row.dart';

/// My starred messages (batch 4), newest star first, across every chat — or
/// just one chat when opened from its details. Tap opens the chat at that
/// message; swipe left unstars.
class StarredMessagesScreen extends ConsumerStatefulWidget {
  final String? conversationId;
  const StarredMessagesScreen({super.key, this.conversationId});

  @override
  ConsumerState<StarredMessagesScreen> createState() => _StarredMessagesScreenState();
}

class _StarredMessagesScreenState extends ConsumerState<StarredMessagesScreen> {
  final _rows = <StarredMessage>[];
  String? _cursor;
  bool _loading = true;
  bool _exhausted = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_exhausted && _rows.isNotEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Keep paging while a per-chat filter leaves this page empty.
      for (var n = 0; n < 10; n++) {
        final page = await ref.read(chatRepositoryProvider).starred(cursor: _cursor);
        final keep = [
          for (final r in page.data)
            if (widget.conversationId == null || r.conversationId == widget.conversationId) r,
        ];
        _rows.addAll(keep);
        _cursor = page.nextCursor;
        _exhausted = page.nextCursor == null;
        if (_exhausted || keep.isNotEmpty) break;
      }
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unstar(StarredMessage r) async {
    setState(() => _rows.removeWhere((x) => x.message.id == r.message.id));
    try {
      await ref.read(chatRepositoryProvider).setStarred(r.message.id, false);
      // The open thread (if any) follows.
      if (ref.exists(messagesProvider(r.conversationId))) {
        ref.read(messagesProvider(r.conversationId).notifier).star(r.message.id, false).catchError((_) {});
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _rows.add(r));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider).user?.id;
    return Scaffold(
      appBar: AppBar(title: const Text(Strings.chatStarredMessages)),
      body: _rows.isEmpty && _loading
          ? const SkeletonList()
          : _rows.isEmpty && _error != null
              ? _Empty(
                  icon: Icons.cloud_off_outlined,
                  title: 'Couldn’t load starred messages',
                  body: ErrorMessages.forApi(_error),
                  action: ('Retry', _loadMore),
                )
              : _rows.isEmpty
                  ? const _Empty(
                      icon: Icons.star_border_rounded,
                      title: Strings.chatStarredEmpty,
                      body: Strings.chatStarredEmptyHint,
                    )
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (!_loading && !_exhausted && n.metrics.pixels > n.metrics.maxScrollExtent - 300) {
                          _loadMore();
                        }
                        return false;
                      },
                      child: ListView.separated(
                        key: const ValueKey('starred-list'),
                        itemCount: _rows.length + (_loading ? 1 : 0),
                        separatorBuilder: (_, _) => const Divider(height: 1, indent: AppSpacing.lg),
                        itemBuilder: (_, i) {
                          if (i >= _rows.length) {
                            return const Padding(
                              padding: EdgeInsets.all(AppSpacing.md),
                              child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
                            );
                          }
                          final r = _rows[i];
                          return SwipeActionRow(
                            key: ValueKey('starred-row-${r.message.id}'),
                            trailing: SwipeAction(
                              key: ValueKey('starred-unstar-${r.message.id}'),
                              icon: Icons.star_outline_rounded,
                              label: Strings.chatUnstar,
                              color: AppColors.amber,
                              onTap: () => _unstar(r),
                            ),
                            child: _StarredRow(
                              row: r,
                              isMine: r.message.senderId == me,
                              onTap: () => context.push(
                                AppRoutes.chatAt(r.conversationId, r.message.id),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

class _StarredRow extends StatelessWidget {
  final StarredMessage row;
  final bool isMine;
  final VoidCallback onTap;
  const _StarredRow({required this.row, required this.isMine, required this.onTap});

  String get _preview {
    final m = row.message;
    if (m.isDeleted) return Strings.chatMessageDeleted;
    return switch (m.type) {
      MessageType.image => '📷 Photo',
      MessageType.voiceNote => '🎤 Voice note',
      MessageType.file => '📄 ${m.fileName ?? 'File'}',
      _ => plainText(m.content ?? ''),
    };
  }

  @override
  Widget build(BuildContext context) {
    final when = row.message.createdAt.toLocal();
    final where = row.conversationName ?? (row.conversationType == ConversationType.group ? 'Group' : 'Chat');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.star_rounded, size: 16, color: AppColors.amber),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    isMine ? '${Strings.chatYou} › $where' : where,
                    style: AppText.caption.copyWith(fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(DateFormat.MMMd().add_jm().format(when), style: AppText.timestamp),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                decoration: BoxDecoration(
                  color: isMine ? AppColors.medBlue : AppColors.white,
                  borderRadius: isMine ? AppRadii.bubbleSent : AppRadii.bubbleReceived,
                  border: isMine ? null : Border.all(color: AppColors.gray100),
                ),
                child: Text(
                  _preview,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.messageBody.copyWith(color: isMine ? AppColors.white : AppColors.textPrimary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback)? action;
  const _Empty({required this.icon, required this.title, required this.body, this.action});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: AppColors.gray400),
              const SizedBox(height: AppSpacing.lg),
              Text(title, style: AppText.heading, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.xs),
              Text(body, style: AppText.caption, textAlign: TextAlign.center),
              if (action != null)
                TextButton(onPressed: action!.$2, child: Text(action!.$1)),
            ],
          ),
        ),
      );
}
