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
import '../../../data/models/conversation.dart';
import '../../../data/models/message.dart';
import '../../../state/auth_state.dart';
import '../../../state/chat_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/primary_button.dart';
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
      // The open thread (if any) follows — only where it holds the row;
      // for one it has not loaded, star() would repeat the server call.
      if (ref.exists(messagesProvider(r.conversationId))) {
        final thread = ref.read(messagesProvider(r.conversationId).notifier);
        if (thread.messageById(r.message.id) != null) {
          thread.star(r.message.id, false).catchError((_) {});
        }
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
    // Mention names: me, and the other person of each direct chat. Anyone
    // else reads "@someone" — never an id.
    final names = <String, String>{
      for (final c in ref.watch(conversationsProvider).asData?.value ?? const <Conversation>[])
        if (c.type == ConversationType.direct && c.displayName != null)
          for (final id in c.memberIds)
            if (id != me) id: c.displayName!,
    };
    String nameFor(String id) => id == me ? Strings.chatYou : (names[id] ?? 'someone');
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
                        // A failed page waits for its Retry instead of refiring on scroll.
                        if (!_loading && _error == null && !_exhausted && n.metrics.pixels > n.metrics.maxScrollExtent - 300) {
                          _loadMore();
                        }
                        return false;
                      },
                      child: ListView.separated(
                        key: const ValueKey('starred-list'),
                        itemCount: _rows.length + (_loading || _error != null ? 1 : 0),
                        separatorBuilder: (_, _) => const Divider(height: 1, indent: AppSpacing.lg),
                        itemBuilder: (_, i) {
                          if (i >= _rows.length && !_loading) {
                            // The next page failed with rows on screen: say
                            // so here, with the button that retries it.
                            return Padding(
                              key: const ValueKey('starred-more-error'),
                              padding: const EdgeInsets.fromLTRB(
                                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  InlineError(ErrorMessages.forApi(_error)),
                                  const SizedBox(height: AppSpacing.sm),
                                  AppButton(
                                    key: const ValueKey('starred-more-retry'),
                                    label: Strings.retry,
                                    icon: Icons.refresh_rounded,
                                    variant: AppButtonVariant.ghost,
                                    expand: true,
                                    onPressed: _loadMore,
                                  ),
                                ],
                              ),
                            );
                          }
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
                              // White label: 7.09:1 here, 2.15:1 on bright amber.
                              color: AppColors.amberText,
                              onTap: () => _unstar(r),
                            ),
                            child: _StarredRow(
                              row: r,
                              isMine: r.message.senderId == me,
                              nameFor: nameFor,
                              onUnstar: () => _unstar(r),
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
  final VoidCallback onUnstar;
  final String Function(String userId) nameFor;
  const _StarredRow({
    required this.row,
    required this.isMine,
    required this.onTap,
    required this.onUnstar,
    required this.nameFor,
  });

  String get _preview {
    final m = row.message;
    if (m.isDeleted) return Strings.chatMessageDeleted;
    final label = switch (m.type) {
      MessageType.image => '📷 Photo',
      MessageType.video => '🎬 ${Strings.mediaVideo}',
      MessageType.voiceNote => '🎤 Voice note',
      MessageType.file => '📄 ${m.fileName ?? 'File'}',
      MessageType.poll => '📊 ${m.poll?.question ?? m.content ?? 'Poll'}',
      _ => plainText(m.content ?? '', nameFor: nameFor),
    };
    // A caption rides under media; a text row is its own content.
    final caption = (m.caption ?? '').trim();
    if (caption.isEmpty || m.type == MessageType.text) return label;
    return label.isEmpty ? caption : '$label\n$caption';
  }

  @override
  Widget build(BuildContext context) {
    final when = row.message.createdAt.toLocal();
    final where = row.conversationName ?? (row.conversationType == ConversationType.group ? 'Group' : 'Chat');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: AppSpacing.lg, right: AppSpacing.xs, top: AppSpacing.md, bottom: AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _content(context, when, where),
            ),
            // Unstar without the swipe: a visible, labelled 48pt button.
            IconButton(
              key: ValueKey('starred-unstar-button-${row.message.id}'),
              tooltip: Strings.chatUnstar,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Icon(Icons.star_rounded, color: AppColors.amberText),
              onPressed: onUnstar,
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, DateTime when, String where) {
    return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Star and chat name share a line; the date sits beside them
            // when it fits and drops to its own line at a large text size,
            // instead of leaving a few characters of the name.
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.sm,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_rounded, size: 16, color: AppColors.amberText),
                      const SizedBox(width: AppSpacing.xs),
                      Flexible(
                        child: Text(
                          isMine ? '${Strings.chatYou} › $where' : where,
                          style: AppText.caption.copyWith(fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  Text(DateFormat.MMMd().add_jm().format(when), style: AppText.timestamp),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.7),
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
              Semantics(
                container: action != null,
                liveRegion: action != null,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: AppText.heading, textAlign: TextAlign.center),
                    const SizedBox(height: AppSpacing.xs),
                    Text(body, style: AppText.caption, textAlign: TextAlign.center),
                  ],
                ),
              ),
              if (action != null)
                TextButton(onPressed: action!.$2, child: Text(action!.$1)),
            ],
          ),
        ),
      );
}
