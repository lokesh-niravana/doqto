import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/motion.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/chat_list_filters.dart';
import '../../../core/utils/datetime_format.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/conversation.dart';
import '../../../data/models/conversation_prefs.dart';
import '../../../data/models/organization.dart';
import '../../../state/auth_state.dart';
import '../../../state/chat_state.dart';
import '../../../state/org_state.dart';
import '../../../state/presence_state.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/connectivity_banner.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/search_bar.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/swipe_action_row.dart';
import '../../widgets/typing_indicator.dart';
import '_conversation_display.dart';
import '../../../core/utils/avatar_urls.dart';

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  String _query = '';
  ChatFilter _filter = ChatFilter.all;
  final Set<String> _selectedIds = {};
  bool _busy = false;
  // Rows stagger-animate only on the very first data paint; refreshes and
  // scrolled-in rows render instantly.
  bool _entranceDone = false;

  bool get _isSelecting => _selectedIds.isNotEmpty;

  void _toggleSelect(String convId) {
    setState(() {
      if (_selectedIds.contains(convId)) {
        _selectedIds.remove(convId);
      } else {
        _selectedIds.add(convId);
      }
    });
  }

  void _clearSelection() => setState(() => _selectedIds.clear());

  List<Conversation> get _selectedConvs {
    final all =
        ref.read(conversationsProvider).asData?.value ?? const <Conversation>[];
    return [
      for (final c in all)
        if (_selectedIds.contains(c.id)) c,
    ];
  }

  /// Run one prefs action over the selection; the first failure is toasted.
  Future<void> _bulk(Future<void> Function(Conversation c) action) async {
    final targets = _selectedConvs;
    setState(() => _busy = true);
    Object? firstError;
    for (final c in targets) {
      try {
        await action(c);
      } catch (e) {
        firstError ??= e;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selectedIds.clear();
    });
    if (firstError != null) ConversationActions.toastError(context, firstError);
  }

  Future<void> _bulkPin() {
    final anyUnpinned = _selectedConvs.any((c) => !c.prefs.isPinned);
    final notifier = ref.read(conversationsProvider.notifier);
    return _bulk((c) => notifier.pin(c.id, anyUnpinned));
  }

  Future<void> _bulkMute() async {
    final anyUnmuted = _selectedConvs.any((c) => !c.prefs.isMuted());
    final notifier = ref.read(conversationsProvider.notifier);
    if (!anyUnmuted) {
      return _bulk((c) => notifier.mute(c.id, null));
    }
    final until = await ConversationActions.pickMuteUntil(context);
    if (until == null || !mounted) return;
    return _bulk((c) => notifier.mute(c.id, until));
  }

  Future<void> _bulkArchive() {
    final anyLive = _selectedConvs.any((c) => !c.prefs.archived);
    final notifier = ref.read(conversationsProvider.notifier);
    return _bulk((c) => notifier.archive(c.id, anyLive));
  }

  Future<void> _bulkMarkUnread() {
    final anyRead = _selectedConvs.any((c) => !isConversationUnread(c));
    final notifier = ref.read(conversationsProvider.notifier);
    return _bulk((c) => notifier.markUnread(c.id, anyRead));
  }

  Future<void> _bulkDelete() async {
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $count chat${count == 1 ? '' : 's'}?'),
        content: const Text(
          'Direct chats are cleared and leave your list until the other person '
          'writes again. Groups are left.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(Strings.cancel),
          ),
          TextButton(
            key: const ValueKey('chat-confirm-delete'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final notifier = ref.read(conversationsProvider.notifier);
    await _bulk((c) => notifier.deleteChat(c.id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted $count chat${count == 1 ? '' : 's'}.'),
        backgroundColor: AppColors.medBlue,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final convs = ref.watch(conversationsProvider);
    final user = ref.watch(authProvider).user;
    final currentOrg = ref.watch(orgProvider).current;
    final membersAsync = currentOrg == null
        ? const AsyncValue<List<OrgMember>>.data([])
        : ref.watch(orgMembersProvider(currentOrg.id));
    final orgMembers = membersAsync.asData?.value ?? const <OrgMember>[];
    if (!_entranceDone && convs.hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_entranceDone) setState(() => _entranceDone = true);
      });
    }
    return Scaffold(
      appBar: _isSelecting
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              ),
              title: Text('${_selectedIds.length} selected'),
              actions: _busy
                  ? const [
                      Padding(
                        padding: EdgeInsets.all(AppSpacing.md),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ]
                  : [
                      IconButton(
                        key: const ValueKey('chat-select-pin'),
                        icon: const Icon(Icons.push_pin_outlined),
                        tooltip: Strings.chatPin,
                        onPressed: _bulkPin,
                      ),
                      IconButton(
                        key: const ValueKey('chat-select-mute'),
                        icon: const Icon(Icons.notifications_off_outlined),
                        tooltip: Strings.chatMute,
                        onPressed: _bulkMute,
                      ),
                      IconButton(
                        key: const ValueKey('chat-select-archive'),
                        icon: const Icon(Icons.archive_outlined),
                        tooltip: Strings.chatArchive,
                        onPressed: _bulkArchive,
                      ),
                      IconButton(
                        key: const ValueKey('chat-select-unread'),
                        icon: const Icon(Icons.mark_chat_unread_outlined),
                        tooltip: Strings.chatMarkUnread,
                        onPressed: _bulkMarkUnread,
                      ),
                      IconButton(
                        key: const ValueKey('chat-select-delete'),
                        icon: const Icon(Icons.delete_outline),
                        tooltip: Strings.chatDeleteChat,
                        onPressed: _bulkDelete,
                      ),
                    ],
            )
          : AppBar(
              toolbarHeight: 64,
              title: Text(
                Strings.appName,
                style: AppText.display.copyWith(fontSize: 28),
              ),
              actions: [
                IconButton(
                  tooltip: 'New message',
                  onPressed: () => context.push(AppRoutes.newMessage),
                  icon: const Icon(Icons.edit_square, color: AppColors.medBlue),
                ),
                if (user != null)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: IconButton(
                      tooltip: 'Profile',
                      onPressed: () => context.push(AppRoutes.profile),
                      icon: DoctorAvatar(
                        initials: user.initials,
                        size: AvatarSize.sm,
                        imageUrl: userAvatarUrl(user.id, user.avatarUrl),
                      ),
                    ),
                  ),
              ],
            ),
      body: Column(
        children: [
          const ConnectivityBanner(),
          if (!_isSelecting) ...[
            AppSearchBar(
              hint: 'Search chats or people…',
              onChanged: (q) => setState(() => _query = q),
            ),
            if (_query.isEmpty)
              _FilterChips(
                value: _filter,
                onChanged: (f) => setState(() => _filter = f),
              ),
          ],
          Expanded(
            child: AnimatedSwitcher(
              duration: AppMotion.maybe(context, AppMotion.enter),
              switchInCurve: AppMotion.curveEnter,
              switchOutCurve: AppMotion.curveExit,
              child: _query.isNotEmpty && !_isSelecting
                  ? _SearchResults(
                      key: const ValueKey('search'),
                      query: _query,
                      conversations: convs.asData?.value ?? const [],
                      orgMembers: orgMembers,
                      meId: user?.id,
                    )
                  : _ConversationList(
                      key: const ValueKey('list'),
                      convs: convs,
                      filter: _filter,
                      onFilter: (f) => setState(() => _filter = f),
                      orgMembers: orgMembers,
                      meId: user?.id,
                      selectedIds: _selectedIds,
                      isSelecting: _isSelecting,
                      onSelect: _toggleSelect,
                      staggerEntrance: !_entranceDone,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// All / Unread / Groups / Archived under the search bar.
class _FilterChips extends StatelessWidget {
  final ChatFilter value;
  final ValueChanged<ChatFilter> onChanged;
  const _FilterChips({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenHorizontal,
        0,
        AppSpacing.screenHorizontal,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          for (final f in ChatFilter.values) ...[
            AppChip(
              key: ValueKey('chat-filter-${f.name}'),
              label: f.label,
              selected: f == value,
              onTap: () => onChanged(f),
            ),
            if (f != ChatFilter.values.last)
              const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// Per-conversation actions shared by the swipe buttons, the More sheet and
/// the multi-select bar. Every call is optimistic through the notifier and
/// toasts the mapped error on failure.
class ConversationActions {
  ConversationActions._();

  static void toastError(BuildContext context, Object e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ),
    );
  }

  static void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), backgroundColor: AppColors.medBlue),
      );
  }

  static Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
    String toast,
  ) async {
    try {
      await action();
      if (context.mounted) _toast(context, toast);
    } catch (e) {
      if (context.mounted) toastError(context, e);
    }
  }

  static Future<void> togglePin(
    BuildContext context,
    WidgetRef ref,
    Conversation c,
  ) {
    final next = !c.prefs.isPinned;
    return _run(
      context,
      () => ref.read(conversationsProvider.notifier).pin(c.id, next),
      next ? Strings.chatPinnedToast : Strings.chatUnpinnedToast,
    );
  }

  static Future<void> toggleArchive(
    BuildContext context,
    WidgetRef ref,
    Conversation c,
  ) {
    final next = !c.prefs.archived;
    return _run(
      context,
      () => ref.read(conversationsProvider.notifier).archive(c.id, next),
      next ? Strings.chatArchivedToast : Strings.chatUnarchivedToast,
    );
  }

  static Future<void> toggleMarkUnread(
    BuildContext context,
    WidgetRef ref,
    Conversation c,
  ) {
    final next = !isConversationUnread(c);
    return _run(
      context,
      () => ref.read(conversationsProvider.notifier).markUnread(c.id, next),
      next ? Strings.chatMarkUnread : Strings.chatMarkRead,
    );
  }

  /// 8 hours / 1 week / Always → the `muted_until` instant, or null if dismissed.
  static Future<DateTime?> pickMuteUntil(BuildContext context) async {
    final picked = await showChoiceSheet<MuteDuration>(
      context,
      title: Strings.chatMuteTitle,
      subtitle: Strings.chatMuteHint,
      options: [for (final d in MuteDuration.values) (d, d.label)],
      wire: (d) => switch (d) {
        MuteDuration.eightHours => '8h',
        MuteDuration.oneWeek => '1w',
        MuteDuration.always => 'always',
      },
      keyPrefix: 'chat',
      field: 'mute',
    );
    return picked?.$1.until();
  }

  static Future<void> toggleMute(
    BuildContext context,
    WidgetRef ref,
    Conversation c,
  ) async {
    if (c.prefs.isMuted()) {
      return _run(
        context,
        () => ref.read(conversationsProvider.notifier).mute(c.id, null),
        Strings.chatUnmutedToast,
      );
    }
    final until = await pickMuteUntil(context);
    if (until == null || !context.mounted) return;
    return _run(
      context,
      () => ref.read(conversationsProvider.notifier).mute(c.id, until),
      Strings.chatMutedToast,
    );
  }

  static Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String action,
    required Key key,
  }) async {
    final ok = await showDialog<bool>(
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
            key: key,
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  static Future<void> clearChat(
    BuildContext context,
    WidgetRef ref,
    Conversation c,
  ) async {
    final ok = await _confirm(
      context,
      title: Strings.chatClearTitle,
      body: Strings.chatClearBody,
      action: Strings.chatClear,
      key: const ValueKey('chat-confirm-clear'),
    );
    if (!ok || !context.mounted) return;
    return _run(
      context,
      () => ref.read(conversationsProvider.notifier).clearChat(c.id),
      Strings.chatClearedToast,
    );
  }

  static Future<void> deleteChat(
    BuildContext context,
    WidgetRef ref,
    Conversation c,
  ) async {
    final isGroup = c.type == ConversationType.group;
    final ok = await _confirm(
      context,
      title: isGroup
          ? Strings.chatLeaveGroupTitle
          : Strings.chatDeleteChatTitle,
      body: isGroup ? Strings.chatLeaveGroupBody : Strings.chatDeleteChatBody,
      action: isGroup ? Strings.chatLeave : Strings.chatDeleteChat,
      key: const ValueKey('chat-confirm-delete'),
    );
    if (!ok || !context.mounted) return;
    return _run(
      context,
      () => ref.read(conversationsProvider.notifier).deleteChat(c.id),
      Strings.chatDeletedToast,
    );
  }

  /// The "More" sheet: Pin · Mute · Mark unread · Clear chat · Delete chat.
  static Future<void> showSheet(
    BuildContext context,
    WidgetRef ref,
    Conversation c,
  ) async {
    final muted = c.prefs.isMuted();
    final unread = isConversationUnread(c);
    final isGroup = c.type == ConversationType.group;
    final choice = await showModalBottomSheet<String>(
      context: context,
      // Root navigator: the tab shell's docked mic button would otherwise
      // float above the sheet's last row.
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const ValueKey('chat-action-pin'),
                leading: const Icon(Icons.push_pin_outlined),
                title: Text(
                  c.prefs.isPinned ? Strings.chatUnpin : Strings.chatPin,
                ),
                onTap: () => Navigator.of(ctx).pop('pin'),
              ),
              ListTile(
                key: const ValueKey('chat-action-mute'),
                leading: Icon(
                  muted
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                ),
                title: Text(muted ? Strings.chatUnmute : Strings.chatMute),
                subtitle: muted && !c.prefs.isMutedAlways
                    ? Text(
                        'Until ${formatChatListTime(c.prefs.mutedUntil!)}',
                        style: AppText.caption,
                      )
                    : null,
                onTap: () => Navigator.of(ctx).pop('mute'),
              ),
              ListTile(
                key: const ValueKey('chat-action-unread'),
                leading: Icon(
                  unread
                      ? Icons.mark_chat_read_outlined
                      : Icons.mark_chat_unread_outlined,
                ),
                title: Text(
                  unread ? Strings.chatMarkRead : Strings.chatMarkUnread,
                ),
                onTap: () => Navigator.of(ctx).pop('unread'),
              ),
              ListTile(
                key: const ValueKey('chat-action-archive'),
                leading: Icon(
                  c.prefs.archived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
                title: Text(
                  c.prefs.archived
                      ? Strings.chatUnarchive
                      : Strings.chatArchive,
                ),
                onTap: () => Navigator.of(ctx).pop('archive'),
              ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('chat-action-clear'),
                leading: const Icon(Icons.cleaning_services_outlined),
                title: const Text(Strings.chatClear),
                onTap: () => Navigator.of(ctx).pop('clear'),
              ),
              ListTile(
                key: const ValueKey('chat-action-delete'),
                leading: const Icon(Icons.delete_outline, color: AppColors.red),
                title: Text(
                  isGroup ? 'Leave group' : Strings.chatDeleteChat,
                  style: const TextStyle(color: AppColors.red),
                ),
                onTap: () => Navigator.of(ctx).pop('delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'pin':
        await togglePin(context, ref, c);
      case 'mute':
        await toggleMute(context, ref, c);
      case 'unread':
        await toggleMarkUnread(context, ref, c);
      case 'archive':
        await toggleArchive(context, ref, c);
      case 'clear':
        await clearChat(context, ref, c);
      case 'delete':
        await deleteChat(context, ref, c);
    }
  }
}

class _ConversationList extends ConsumerWidget {
  final AsyncValue<List<Conversation>> convs;
  final ChatFilter filter;
  final ValueChanged<ChatFilter> onFilter;
  final List<OrgMember> orgMembers;
  final String? meId;
  final Set<String> selectedIds;
  final bool isSelecting;
  final ValueChanged<String> onSelect;
  final bool staggerEntrance;

  const _ConversationList({
    super.key,
    required this.convs,
    required this.filter,
    required this.onFilter,
    required this.orgMembers,
    required this.meId,
    required this.selectedIds,
    required this.isSelecting,
    required this.onSelect,
    required this.staggerEntrance,
  });

  Widget _empty(BuildContext context) => switch (filter) {
    ChatFilter.all => _StatusPane(
      icon: Icons.chat_bubble_outline_rounded,
      title: 'No conversations yet',
      subtitle: 'Message a colleague or start a group to get going.',
      actionLabel: 'Start a conversation',
      onAction: () => context.push(AppRoutes.newMessage),
    ),
    ChatFilter.unread => const _StatusPane(
      icon: Icons.mark_chat_read_outlined,
      title: Strings.chatUnreadEmpty,
      subtitle: Strings.chatUnreadEmptyHint,
    ),
    ChatFilter.groups => _StatusPane(
      icon: Icons.groups_outlined,
      title: Strings.chatGroupsEmpty,
      subtitle: Strings.chatGroupsEmptyHint,
      actionLabel: 'Open Groups',
      onAction: () => context.go(AppRoutes.groups),
    ),
    ChatFilter.archived => const _StatusPane(
      icon: Icons.archive_outlined,
      title: Strings.chatArchivedEmpty,
      subtitle: Strings.chatArchivedEmptyHint,
    ),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return convs.when(
      // Cached data paints instantly (AsyncData); the skeleton only ever
      // shows on a true cold start with nothing cached.
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const SkeletonList(),
      error: (e, _) => _StatusPane(
        icon: Icons.cloud_off_rounded,
        title: 'Couldn’t load your chats',
        subtitle: ErrorMessages.forApi(e),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(conversationsProvider),
      ),
      data: (rawList) {
        final sorted = sortConversations(rawList);
        final list = applyChatFilter(sorted, filter);
        final archivedCount = rawList.where((c) => c.prefs.archived).length;
        // Archived (n) row: top when pinned chats lead the list, bottom
        // otherwise. Never inside the Archived view itself.
        final showArchivedRow =
            filter != ChatFilter.archived && archivedCount > 0;
        final archivedOnTop =
            showArchivedRow && list.isNotEmpty && list.first.prefs.isPinned;
        final drafts = ref.watch(draftsProvider);
        // Follow presence for the direct peers on screen (newest chats
        // first; the notifier caps one call at 50 ids).
        final peers = <String>[for (final c in list) ?directPeerId(c, meId)];
        if (peers.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(presenceProvider.notifier).track(peers);
          });
        }
        final archivedRow = showArchivedRow
            ? _ArchivedRow(
                count: archivedCount,
                onTap: () => onFilter(ChatFilter.archived),
              )
            : null;
        final bottom = MediaQuery.paddingOf(context).bottom + AppSpacing.sm;
        return RefreshIndicator(
          onRefresh: () => ref.read(conversationsProvider.notifier).refresh(),
          child: list.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    ?archivedRow,
                    SizedBox(height: MediaQuery.of(context).size.height * 0.18),
                    _empty(context),
                  ],
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  // extendBody: keep last row clear of the floating nav bar.
                  padding: EdgeInsets.only(top: AppSpacing.sm, bottom: bottom),
                  itemCount: list.length + (archivedRow != null ? 1 : 0),
                  separatorBuilder: (ctx, i) => const Divider(
                    indent: AppSpacing.xxl + AppSpacing.lg,
                    height: 0,
                  ),
                  itemBuilder: (ctx, i) {
                    if (archivedRow != null) {
                      if (archivedOnTop && i == 0) return archivedRow;
                      if (!archivedOnTop && i == list.length) {
                        return archivedRow;
                      }
                    }
                    final idx = archivedRow != null && archivedOnTop
                        ? i - 1
                        : i;
                    final c = list[idx];
                    final display = conversationDisplay(
                      c: c,
                      orgMembers: orgMembers,
                      meId: meId,
                      fallbackColorIndex: idx,
                    );
                    return FadeSlideIn.staggered(
                      idx,
                      _ChatRow(
                        conversation: c,
                        display: display,
                        orgMembers: orgMembers,
                        meId: meId,
                        draft: drafts[c.id],
                        isSelected: selectedIds.contains(c.id),
                        isSelecting: isSelecting,
                        onSelect: onSelect,
                        swipeable: !isSelecting,
                      ),
                      enabled: staggerEntrance && idx <= AppMotion.staggerCap,
                    );
                  },
                ),
        );
      },
    );
  }
}

/// "Archived (n)" — opens the Archived filter.
class _ArchivedRow extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _ArchivedRow({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppPressable(
      key: const ValueKey('chat-archived-row'),
      onTap: onTap,
      child: ListTile(
        leading: const SizedBox(
          width: 48,
          child: Center(
            child: Icon(Icons.archive_outlined, color: AppColors.medBlue),
          ),
        ),
        title: Text(
          Strings.chatArchivedRow(count),
          style: AppText.heading.copyWith(color: AppColors.medBlue),
        ),
        trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
      ),
    );
  }
}

class _SearchResults extends ConsumerStatefulWidget {
  final String query;
  final List<Conversation> conversations;
  final List<OrgMember> orgMembers;
  final String? meId;

  const _SearchResults({
    super.key,
    required this.query,
    required this.conversations,
    required this.orgMembers,
    required this.meId,
  });

  @override
  ConsumerState<_SearchResults> createState() => _SearchResultsState();
}

class _SearchResultsState extends ConsumerState<_SearchResults> {
  final Set<String> _startingChat = {};

  bool _matchConversation(Conversation c) {
    final q = widget.query.toLowerCase();
    final display = conversationDisplay(
      c: c,
      orgMembers: widget.orgMembers,
      meId: widget.meId,
      fallbackColorIndex: 0,
    );
    if (display.title.toLowerCase().contains(q)) return true;
    return c.lastMessagePreview != null &&
        c.lastMessagePreview!.toLowerCase().contains(q);
  }

  bool _matchMember(OrgMember m) {
    if (m.id == widget.meId) return false;
    final q = widget.query.toLowerCase();
    if (m.fullName.toLowerCase().contains(q)) return true;
    return m.specialty != null && m.specialty!.toLowerCase().contains(q);
  }

  Future<void> _startChat(OrgMember m) async {
    if (_startingChat.contains(m.id)) return;
    setState(() => _startingChat.add(m.id));
    try {
      final conv = await ref
          .read(chatRepositoryProvider)
          .createConversation(
            type: ConversationType.direct,
            name: null,
            memberIds: [m.id],
          );
      if (!mounted) return;
      context.push(AppRoutes.chat(conv.id));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _startingChat.remove(m.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final matchingConvs = widget.conversations
        .where(_matchConversation)
        .toList();
    final matchingMembers = widget.orgMembers.where(_matchMember).toList();

    if (matchingConvs.isEmpty && matchingMembers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 40,
              color: AppColors.gray400,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'No results for "${widget.query}"',
              style: AppText.body,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Try a different name or specialty.',
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.only(
        top: AppSpacing.sm,
        bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.sm,
      ),
      children: [
        if (matchingConvs.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenHorizontal,
              AppSpacing.sm,
              AppSpacing.screenHorizontal,
              AppSpacing.xs,
            ),
            child: Text('CONVERSATIONS', style: AppText.label),
          ),
          for (var i = 0; i < matchingConvs.length; i++)
            _ChatRow(
              conversation: matchingConvs[i],
              display: conversationDisplay(
                c: matchingConvs[i],
                orgMembers: widget.orgMembers,
                meId: widget.meId,
                fallbackColorIndex: i,
              ),
              orgMembers: widget.orgMembers,
              meId: widget.meId,
            ),
        ],
        if (matchingMembers.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenHorizontal,
              AppSpacing.lg,
              AppSpacing.screenHorizontal,
              AppSpacing.xs,
            ),
            child: Text('PEOPLE', style: AppText.label),
          ),
          for (final m in matchingMembers)
            AppPressable(
              onTap: () => context.push(AppRoutes.person(m.id)),
              child: ListTile(
                leading: DoctorAvatar(
                  initials: m.initials,
                  colorIndex: widget.orgMembers.indexOf(m),
                  imageUrl: userAvatarUrl(m.id, m.avatarUrl),
                ),
                title: Text(
                  m.fullName,
                  style: AppText.heading,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  m.specialty ?? '',
                  style: AppText.caption,
                  maxLines: 1,
                ),
                trailing: SizedBox(
                  width: 40,
                  height: 40,
                  child: _startingChat.contains(m.id)
                      ? const Padding(
                          padding: EdgeInsets.all(AppSpacing.sm),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          tooltip: 'Message',
                          icon: const Icon(Icons.chat_bubble_outline),
                          color: AppColors.medBlue,
                          onPressed: () => _startChat(m),
                        ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _ChatRow extends ConsumerWidget {
  final Conversation conversation;
  final ConversationDisplay display;
  final List<OrgMember> orgMembers;
  final String? meId;
  final String? draft;
  final bool isSelected;
  final bool isSelecting;
  final bool swipeable;
  final ValueChanged<String>? onSelect;

  const _ChatRow({
    required this.conversation,
    required this.display,
    required this.orgMembers,
    required this.meId,
    this.draft,
    this.isSelected = false,
    this.isSelecting = false,
    this.swipeable = false,
    this.onSelect,
  });

  String? _resolveSenderFirstName(String senderId) {
    for (final m in orgMembers) {
      if (m.id == senderId) {
        final first = m.fullName.trim().split(RegExp(r'\s+')).first;
        return first.isEmpty ? null : first;
      }
    }
    return null;
  }

  String _previewText() {
    final c = conversation;
    final senderId = c.lastMessageSenderId;
    final isMine = senderId != null && senderId == meId;
    final type = c.lastMessageType;
    if (type == null) return 'Tap to start chatting';
    String body;
    switch (type) {
      case MessageType.text:
        body = c.lastMessagePreview ?? '';
        break;
      case MessageType.voiceNote:
        body = '🎙 Voice note';
        break;
      case MessageType.image:
        body = '📷 Photo';
        break;
      case MessageType.file:
        body = '📎 File';
        break;
      case MessageType.video:
        body = '🎬 Video';
        break;
      case MessageType.poll:
        body = '📊 ${c.lastMessagePreview ?? 'Poll'}';
        break;
      case MessageType.system:
        return c.lastMessagePreview ?? '';
      case MessageType.unknown:
        // Tolerant fallback (A5): render like text, never crash.
        body = c.lastMessagePreview ?? '';
        break;
    }
    if (body.isEmpty) return 'Tap to start chatting';
    if (isMine) return 'You: $body';
    if (!display.isDirect && senderId != null) {
      final name = _resolveSenderFirstName(senderId);
      if (name != null) return '$name: $body';
    }
    return body;
  }

  /// The other member of a direct chat; null for groups.
  String? get peerId =>
      display.isDirect ? directPeerId(conversation, meId) : null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = conversation;
    final hasMsg = c.lastMessageType != null;
    final isUnread = isConversationUnread(c);
    final isTyping = ref.watch(typingProvider(c.id));
    final peer = peerId;
    final titleStyle = isUnread
        ? AppText.heading.copyWith(fontWeight: FontWeight.w700)
        : AppText.heading;
    final previewStyle = isUnread
        ? AppText.caption.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          )
        : hasMsg
        ? AppText.caption.copyWith(color: AppColors.textSecondary)
        : AppText.caption.copyWith(fontStyle: FontStyle.italic);
    final draftText = draft?.trim();
    final Widget subtitle;
    if (isTyping) {
      subtitle = Row(
        children: [
          Text(
            'typing',
            style: AppText.caption.copyWith(
              color: AppColors.medBlue,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 5),
          const TypingDots(color: AppColors.medBlue, size: 6),
        ],
      );
    } else if (draftText != null && draftText.isNotEmpty) {
      // Unsent text wins over the last message, like every messenger.
      subtitle = Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: Strings.chatDraftPrefix,
              style: AppText.caption.copyWith(
                color: AppColors.red,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: draftText,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
        key: ValueKey('chat-draft-${c.id}'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else {
      subtitle = Text(
        _previewText(),
        style: previewStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final tile = AppPressable(
      onTap: () {
        if (isSelecting) {
          onSelect?.call(c.id);
        } else {
          context.push(AppRoutes.chat(c.id));
        }
      },
      onLongPress: () => onSelect?.call(c.id),
      child: ListTile(
        tileColor: isSelected ? AppColors.medBlueLight : null,
        leading: DoctorAvatar(
          initials: display.initials,
          colorIndex: display.colorIndex,
          imageUrl: userAvatarUrl(display.otherUser?.id, display.otherUser?.avatarUrl),
          isSelected: isSelected,
          presence: peer == null
              ? null
              : PresenceStatusDot.forStatus(
                  ref.watch(presenceOfProvider(peer))?.status,
                ),
        ),
        title: Text(
          display.title,
          style: titleStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: subtitle,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              formatChatListTime(c.lastMessageAt ?? c.updatedAt),
              style: isUnread
                  ? AppText.timestamp.copyWith(
                      color: AppColors.medBlue,
                      fontWeight: FontWeight.w600,
                    )
                  : AppText.timestamp,
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (c.prefs.isMuted())
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: Icon(
                      Icons.notifications_off_outlined,
                      key: ValueKey('chat-muted-${c.id}'),
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                  ),
                if (c.prefs.isPinned)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: Icon(
                      Icons.push_pin,
                      key: ValueKey('chat-pinned-${c.id}'),
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                  ),
                if (c.unreadCount > 0)
                  // Badge pill scales in when a row first becomes unread.
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: AppMotion.maybe(context, AppMotion.micro),
                    curve: AppMotion.standard,
                    builder: (context, scale, child) =>
                        Transform.scale(scale: scale, child: child),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.medBlue,
                        borderRadius: AppRadii.rFull,
                      ),
                      constraints: const BoxConstraints(minWidth: 20),
                      child: Text(
                        c.unreadCount > 99 ? '99+' : '${c.unreadCount}',
                        style: AppText.badge.copyWith(color: AppColors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else if (c.prefs.markedUnread)
                  // Hand-set unread: a dot, no number.
                  Container(
                    key: ValueKey('chat-unread-dot-${c.id}'),
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: AppColors.medBlue,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    if (!swipeable) return tile;
    return SwipeActionRow(
      key: ValueKey('chat-row-${c.id}'),
      leading: SwipeAction(
        key: ValueKey('chat-swipe-more-${c.id}'),
        icon: Icons.more_horiz,
        label: Strings.chatMore,
        color: AppColors.gray600,
        onTap: () => ConversationActions.showSheet(context, ref, c),
      ),
      trailing: SwipeAction(
        key: ValueKey('chat-swipe-archive-${c.id}'),
        icon: c.prefs.archived
            ? Icons.unarchive_outlined
            : Icons.archive_outlined,
        label: c.prefs.archived ? Strings.chatUnarchive : Strings.chatArchive,
        color: AppColors.medBlue,
        onTap: () => ConversationActions.toggleArchive(context, ref, c),
      ),
      child: tile,
    );
  }
}

/// Shared empty/error pane: icon + one line + one action. No blank screens.
class _StatusPane extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _StatusPane({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xxl,
          vertical: AppSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.gray400),
            const SizedBox(height: AppSpacing.lg),
            Text(title, style: AppText.heading, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.xs),
            Text(subtitle, style: AppText.caption, textAlign: TextAlign.center),
            if (actionLabel != null && actionLabel!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              AppButton(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}
