import 'dart:async';

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

import '../../../core/di/providers.dart';
import '../../../core/constants/strings.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/motion.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/shadows.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/album_grouping.dart';
import '../../../core/utils/datetime_format.dart';
import '../../../core/utils/image_metadata.dart';
import '../../../core/utils/error_messages.dart';
import '../../../core/utils/rich_text.dart';
import '../../../data/api/api_client.dart';
import '../../../data/models/conversation.dart';
import '../../../data/models/group.dart';
import '../../../data/models/media.dart';
import '../../../data/models/media_settings.dart';
import '../../../data/models/message.dart';
import '../../../data/models/message_edit.dart';
import '../../../data/models/organization.dart';
import '../../../state/auth_state.dart';
import '../../../state/chat_state.dart';
import '../../../data/api/websocket_client.dart';
import '../../../state/groups_state.dart';
import '../../../state/notification_state.dart';
import '../../../state/compliance_state.dart';
import '../../../state/org_state.dart';
import '../../../state/presence_state.dart';
import '../../../state/link_preview_state.dart';
import '../../../state/media_settings_state.dart';
import '../../../state/voice_playback_state.dart';
import '../../widgets/album_bubble.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/attachment_bubbles.dart';
import '../../widgets/connectivity_banner.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/emoji_picker_sheet.dart';
import '../../widgets/inline_banner.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/message_receipts_sheet.dart';
import '../../widgets/external_link_confirm.dart';
import '../../widgets/link_preview_card.dart';
import '../../widgets/mention_autocomplete.dart';
import '../../widgets/mention_controller.dart';
import '../../widgets/message_context_menu.dart';
import '../../widgets/message_text.dart';
import '../../widgets/pinned_banner.dart';
import '../../widgets/poll_bubble.dart';
import '../../widgets/quote_strip.dart';
import '../../widgets/reactions.dart';
import '../../widgets/report_message_sheet.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/swipe_to_reply.dart';
import '../../widgets/typing_indicator.dart';
import '../../widgets/unread_divider.dart';
import '../../widgets/voice_note_bubble.dart';
import '_conversation_display.dart';
import '../media/media_viewer_screen.dart';
import '../compliance/scheduled_messages_sheet.dart';
import 'caption_sheet.dart';
import 'forward_picker_sheet.dart';
import 'poll_create_sheet.dart';
import 'voice_recorder_panel.dart';

/// Pin durations — mirror of PIN_DURATIONS_SEC on the backend.
const List<(int, String)> kPinDurations = [
  (86400, '24 hours'),
  (604800, '7 days'),
  (2592000, '30 days'),
];

class ChatThreadScreen extends ConsumerStatefulWidget {
  final String conversationId;

  /// The network group this thread belongs to, when the caller already knows
  /// it (the group route). Otherwise it comes from the conversation.
  final String? groupId;

  /// Open scrolled to (and highlighting) this message — the starred list.
  final String? initialMessageId;

  const ChatThreadScreen({
    super.key,
    required this.conversationId,
    this.groupId,
    this.initialMessageId,
  });

  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen>
    with WidgetsBindingObserver {
  final _input = MentionController();
  final _scroll = ScrollController();
  bool _showRecorder = false;
  // Batch 5 D: hold-to-record. The mic is a plain icon; a [Listener] over the
  // whole composer area owns the pointer, because the composer is swapped
  // for the recorder panel mid-gesture and a recognizer on the mic itself
  // would die with it.
  bool _recorderHeld = false;
  final _recorderKey = GlobalKey<VoiceRecorderPanelState>();
  final _micKey = GlobalKey();
  Timer? _holdTimer;
  Offset? _micDown;
  bool _holding = false;
  static const _holdDelay = Duration(milliseconds: 300);
  // Batch 5 G: what downloads without a tap on this network, resolved once
  // per open (settings + radio), re-resolved when the settings change.
  final Map<MediaDownloadKind, bool> _auto = {};
  bool _typing = false;
  bool _hasText = false;
  Timer? _typingPing;
  // Composer edit mode: the sent message whose text is being replaced.
  Message? _editing;

  // ---- Batch 4 ------------------------------------------------------------
  // Composer reply mode: the message the next send quotes.
  ReplyPreview? _replyingTo;
  // One GlobalKey per message row so a jump can bring it into view.
  final _rowKeys = <String, GlobalKey>{};
  // The row a jump landed on (quote tap, pin banner, search hit): amber outline
  // that clears after a moment.
  String? _highlightId;
  Timer? _highlightTimer;
  bool _jumping = false;
  // In-chat search (on-device over loaded pages).
  bool _searching = false;
  final _searchInput = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _searchDebounce;
  String _searchQuery = '';
  List<String> _hits = const [];
  int _hitIndex = -1;
  bool _searchBusy = false;
  // Jump to first unread: the unread count when the thread opened and the
  // message the divider sits above (oldest unread).
  int? _unreadAtOpen;
  String? _unreadDividerId;
  bool _unreadResolved = false;
  bool _initialJumpDone = false;
  // Composer link preview (debounced while typing; dismissable per URL).
  Timer? _previewDebounce;
  String? _composerPreviewUrl;
  String? _dismissedPreviewUrl;
  // @mention autocomplete (groups): the query under the caret, if any.
  ({String query, int start})? _mentionActive;
  // Draft (batch 3): unsent text survives leaving the thread. Saved a beat
  // after typing stops and again on dispose; cleared on send.
  Timer? _draftSave;
  String _draftBeforeEdit = '';

  /// WhatsApp-style selection mode: long-press starts it, taps toggle.
  final _selected = <String>{};
  bool get _selecting => _selected.isNotEmpty;

  // --- New-message entrance tracking (screen-local; no state-layer changes).
  // Messages present at first build (and older pages loaded later) never
  // animate; only messages created after the screen opened do.
  final DateTime _openedAt = DateTime.now().toUtc();
  final Set<String> _knownIds = {};
  final Set<String> _entranceIds = {};
  bool _seededIds = false;

  // --- Scroll-to-bottom pill (screen-local).
  static const double _jumpThresholdPx = 400;
  bool _showJump = false;
  int _unseenCount = 0;

  // A message that landed while nobody could see this chat (app in the
  // background, phone locked, another screen pushed on top). The socket stays
  // up through short app-switches, so without this the sender got blue ticks
  // for messages still sitting unseen on a locked phone.
  bool _readOwed = false;

  bool get _visible {
    final life = WidgetsBinding.instance.lifecycleState;
    final onScreen = life == null || life == AppLifecycleState.resumed;
    return onScreen && (ModalRoute.of(context)?.isCurrent ?? true);
  }

  /// Blue ticks mean a person saw it: mark read only while this chat is on
  /// screen, otherwise owe the read until it is.
  void _markReadIfVisible() {
    if (!mounted) return;
    if (!_visible) {
      _readOwed = true;
      return;
    }
    _readOwed = false;
    ref
        .read(chatRepositoryProvider)
        .markConversationRead(widget.conversationId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _readOwed) _markReadIfVisible();
  }

  // Captured up front: `ref` is already unusable by the time dispose() runs,
  // and leaving the thread must still send typing_stop, save the draft and
  // release the active chat.
  late final WebsocketClient _ws;
  late final DraftsNotifier _drafts;
  late final StateController<String?> _activeChat;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ws = ref.read(websocketClientProvider);
    _drafts = ref.read(draftsProvider.notifier);
    _activeChat = ref.read(activeConversationProvider.notifier);
    unawaited(_resolveAutoDownload());
    // Unread position before opening marks the chat read (jump to unread).
    _unreadAtOpen = ref
        .read(conversationsProvider.notifier)
        .conversation(widget.conversationId)
        ?.unreadCount;
    if ((_unreadAtOpen ?? 0) == 0 || widget.initialMessageId != null) {
      _unreadResolved = true;
    }
    // Restore an unsent draft (encrypted cache) exactly as it was left.
    final draft = ref.read(draftsProvider)[widget.conversationId];
    if (draft != null && draft.isNotEmpty) {
      // Drafts hold the wire form; names resolve once members are known
      // (see [_restoreDraftMentions]).
      _input.text = draft;
      _hasText = draft.trim().isNotEmpty;
      _input.selection = TextSelection.collapsed(offset: draft.length);
    }
    // Infinite scroll-back: nearing the top (= end of the reversed list)
    // pulls the next older page.
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
        ref.read(messagesProvider(widget.conversationId).notifier).loadOlder();
      }
      final showJump = _scroll.position.pixels > _jumpThresholdPx;
      if (showJump != _showJump) {
        setState(() {
          _showJump = showJump;
          if (!showJump) _unseenCount = 0; // back at bottom = caught up
        });
      }
    });
    // Opening the thread = reading it: flip the sender's ticks to double-check.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markReadIfVisible();
      // This chat is on screen: suppress banners for it and clear any shown.
      ref.read(activeConversationProvider.notifier).state =
          widget.conversationId;
      ref
          .read(notificationServiceProvider)
          .cancelForConversation(widget.conversationId);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _holdTimer?.cancel();
    _draftSave?.cancel();
    _highlightTimer?.cancel();
    _searchDebounce?.cancel();
    _previewDebounce?.cancel();
    _searchInput.dispose();
    _searchFocus.dispose();
    // Providers must not change while the tree is being torn down; the
    // values are read now and written a microtask later.
    final draft = _editing == null ? _input.wireText : _draftBeforeEdit;
    final convId = widget.conversationId;
    scheduleMicrotask(() {
      // The container itself may be gone when the whole app is torn down
      // (exit / test teardown); nothing is left to update then.
      try {
        if (_activeChat.state == convId) _activeChat.state = null;
        // Whatever was in the composer (not an edit in progress) is the draft.
        _drafts.set(convId, draft);
      } on StateError {
        // provider disposed
      }
    });
    _stopTyping();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Tap on a failed bubble: offer retry / discard.
  Future<void> _onFailedTap(String clientId) async {
    final notifier = ref.read(messagesProvider(widget.conversationId).notifier);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.refresh, color: AppColors.medBlue),
              title: const Text('Retry send'),
              onTap: () => Navigator.pop(ctx, 'retry'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.red),
              title: const Text('Delete message'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'retry') await notifier.retry(clientId);
    if (action == 'delete') await notifier.discard(clientId);
  }

  void _toggleSelect(Message m) {
    setState(
      () => _selected.contains(m.id)
          ? _selected.remove(m.id)
          : _selected.add(m.id),
    );
  }

  void _clearSelection() => setState(_selected.clear);

  List<Message> _selectedMessages() {
    final all = ref.read(messagesProvider(widget.conversationId)).value ?? [];
    return [
      for (final m in all)
        if (_selected.contains(m.id)) m,
    ];
  }

  /// Edit only when exactly one own text message is selected and its window
  /// is open (WhatsApp hides the pencil otherwise).
  Message? _editable() {
    final me = ref.read(authProvider).user?.id;
    final sel = _selectedMessages();
    if (me == null || sel.length != 1 || !sel.first.canEdit(me: me)) {
      return null;
    }
    return sel.first;
  }

  /// Owner / admin of a network group: may delete anyone's message at any
  /// age (server `can_moderate`) and pin.
  bool get _isGroupAdmin {
    final groupId = _groupId;
    if (groupId == null) return false;
    return ref.read(groupDetailProvider(groupId)).asData?.value.canManage ?? false;
  }

  Conversation? get _conv =>
      ref.read(conversationsProvider.notifier).conversation(widget.conversationId);

  /// The group behind this thread: passed in from the Groups tab, or the
  /// `group_id` the conversation carries when the chat list opened it. Null
  /// for direct and legacy org group chats.
  String? get _groupId => widget.groupId ?? _conv?.groupId;

  /// Org policy `allow_copy` (batch 4): hidden when my org forbids copying
  /// and this chat belongs to it. Read from the live policies provider
  /// (batch 7), which refetches on `org_updated`.
  bool get _allowCopy {
    final org = ref.read(orgProvider).current;
    if (org == null || ref.read(currentOrgPoliciesProvider).allowCopy) return true;
    final conv = _conv;
    final groupId = _groupId;
    final group = groupId == null ? null : ref.read(groupDetailProvider(groupId)).asData?.value;
    return conv?.orgId != org.id && group?.orgId != org.id;
  }

  /// WhatsApp's dialog: "Delete for me" always; "Delete for everyone" when
  /// every selected message is mine and inside the 48-hour window — or I am
  /// a group admin.
  Future<void> _deleteSelected() async {
    final me = ref.read(authProvider).user?.id;
    final sel = _selectedMessages();
    if (me == null || sel.isEmpty) return;
    final admin = _isGroupAdmin;
    final forEveryone = sel.every((m) => m.canDelete(me: me, isAdmin: admin));
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Strings.chatDeleteTitle(sel.length)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            TextButton(
              key: const ValueKey('delete-for-me'),
              onPressed: () => Navigator.pop(ctx, 'me'),
              child: const Text(Strings.chatDeleteForMe),
            ),
            if (forEveryone)
              TextButton(
                key: const ValueKey('delete-for-everyone'),
                onPressed: () => Navigator.pop(ctx, 'everyone'),
                child: const Text(Strings.chatDeleteForEveryone),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(Strings.cancel),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    _clearSelection();
    if (_editing != null && sel.any((m) => m.id == _editing!.id)) _cancelEdit();
    final notifier = ref.read(messagesProvider(widget.conversationId).notifier);
    try {
      if (choice == 'me') {
        await notifier.hide([for (final m in sel) m.id]);
      } else {
        for (final m in sel) {
          await notifier.delete(m.id);
        }
      }
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    }
  }

  /// With exactly one of my own sent messages selected, "Message info"
  /// (who has read / received it) is on offer.
  Message? _infoable() {
    final me = ref.read(authProvider).user?.id;
    final sel = _selectedMessages();
    if (me == null || sel.length != 1) return null;
    final m = sel.first;
    if (m.senderId != me ||
        m.status != MessageStatus.sent ||
        m.isDeleted ||
        m.type == MessageType.system) {
      return null;
    }
    return m;
  }

  void _showMessageInfo(Message m) {
    _clearSelection();
    showMessageReceiptsSheet(context: context, message: m);
  }

  /// Selection-mode app bar: count, info (single own message), pencil
  /// (single editable), forward, star, trash.
  PreferredSizeWidget _selectionBar() {
    final editable = _editable();
    final infoable = _infoable();
    final sel = _selectedMessages();
    final forwardable = sel.isNotEmpty && sel.every((m) => m.canForward);
    final starrable = sel.isNotEmpty && sel.every((m) => m.canStar);
    return AppBar(
      leading: IconButton(
        key: const ValueKey('select-close'),
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('${_selected.length}'),
      actions: [
        if (forwardable)
          IconButton(
            key: const ValueKey('select-forward'),
            icon: const Icon(Icons.shortcut_rounded),
            tooltip: Strings.chatForward,
            onPressed: () {
              final picked = _selectedMessages();
              _clearSelection();
              _forward(picked);
            },
          ),
        if (starrable)
          IconButton(
            key: const ValueKey('select-star'),
            icon: Icon(sel.every((m) => m.starred) ? Icons.star_rounded : Icons.star_border_rounded),
            tooltip: Strings.chatStar,
            onPressed: () {
              final picked = _selectedMessages();
              final unstar = picked.every((m) => m.starred);
              _clearSelection();
              for (final m in picked) {
                _star(m, !unstar);
              }
            },
          ),
        if (infoable != null)
          IconButton(
            key: const ValueKey('select-info'),
            icon: const Icon(Icons.info_outline),
            tooltip: Strings.groupMessageInfo,
            onPressed: () => _showMessageInfo(infoable),
          ),
        if (editable != null)
          IconButton(
            key: const ValueKey('select-edit'),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () {
              _clearSelection();
              _startEdit(editable);
            },
          ),
        IconButton(
          key: const ValueKey('select-delete'),
          icon: const Icon(Icons.delete_outline),
          onPressed: _deleteSelected,
        ),
      ],
    );
  }

  void _startEdit(Message m) {
    _draftSave?.cancel();
    if (_editing == null) _draftBeforeEdit = _input.text;
    setState(() {
      _editing = m;
      _replyingTo = null;
      _input.setFromWire(m.content ?? '', _nameFor);
      _hasText = _input.text.trim().isNotEmpty;
    });
  }

  void _cancelEdit() {
    // Back to the draft that was there before editing started.
    final restore = _draftBeforeEdit;
    _draftBeforeEdit = '';
    setState(() {
      _editing = null;
      _input.text = restore;
      _hasText = restore.trim().isNotEmpty;
    });
    _stopTyping();
  }

  Future<void> _submitEdit(Message m, String text) async {
    _cancelEdit();
    if (text == m.content) return; // nothing changed
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .edit(m.id, text);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    }
  }

  /// Every earlier version of an edited message, newest first — either side.
  Future<void> _showEditHistory(Message m) async {
    final future = ref.read(chatRepositoryProvider).messageEdits(m.id);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: FutureBuilder<List<MessageEdit>>(
          future: future,
          builder: (ctx, snap) {
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text(ErrorMessages.forApi(snap.error)),
              );
            }
            if (!snap.hasData) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            final edits = snap.data!.reversed.toList();
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              children: [
                ListTile(
                  title: Text(Strings.chatEditHistory, style: AppText.label),
                  subtitle: Text(
                    '${Strings.chatEdited} ${DateFormat.yMMMd().add_jm().format((m.editedAt ?? m.createdAt).toLocal())}',
                    style: AppText.caption,
                  ),
                ),
                const Divider(height: 1),
                if (edits.isEmpty)
                  const ListTile(title: Text(Strings.chatEditHistoryEmpty))
                else
                  for (final e in edits)
                    ListTile(
                      title: Text(e.content, style: AppText.messageBody),
                      subtitle: Text(
                        DateFormat.yMMMd().add_jm().format(
                          e.replacedAt.toLocal(),
                        ),
                        style: AppText.timestamp,
                      ),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _wsTyping(bool typing) {
    _ws.send({
      'type': typing
          ? WsEventClient.typingStart.wire
          : WsEventClient.typingStop.wire,
      'conversation_id': widget.conversationId,
    });
  }

  void _stopTyping() {
    _typingPing?.cancel();
    _typingPing = null;
    if (_typing) {
      _typing = false;
      _wsTyping(false);
    }
  }

  void _saveDraftSoon(String value) {
    if (_editing != null) return;
    _draftSave?.cancel();
    _draftSave = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      ref.read(draftsProvider.notifier).set(widget.conversationId, _input.wireText);
    });
  }

  void _onInputChanged(String value) {
    final hasText = value.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    _saveDraftSoon(value);
    _updateMentionState();
    _updateComposerPreview(value);
    if (hasText) {
      if (!_typing) {
        _typing = true;
        _wsTyping(true);
        // Re-ping while text is present so the other side's indicator never
        // times out mid-message.
        _typingPing = Timer.periodic(const Duration(seconds: 3), (_) {
          if (_typing) _wsTyping(true);
        });
      }
    } else {
      _stopTyping();
    }
  }

  Future<void> _send() async {
    final text = _input.wireText.trim();
    if (text.isEmpty) return;
    final editing = _editing;
    if (editing != null) {
      return _submitEdit(editing, text);
    }
    final replyTo = _replyingTo;
    _input.clear();
    setState(() {
      _hasText = false; // clear() doesn't fire onChanged
      _replyingTo = null;
      _composerPreviewUrl = null;
      _dismissedPreviewUrl = null;
      _mentionActive = null;
    });
    _stopTyping();
    _draftSave?.cancel();
    unawaited(ref.read(draftsProvider.notifier).clear(widget.conversationId));
    await ref
        .read(messagesProvider(widget.conversationId).notifier)
        .sendText(text, replyTo: replyTo);
  }

  // ---- Batch 4: reply / forward / star / pin / copy / report ---------------

  /// Name shown for [uid] in quotes, mentions, the pin banner. Null when we
  /// don't know them (a former member).
  String? _nameFor(String uid) {
    if (uid == ref.read(authProvider).user?.id) return Strings.chatYou;
    final member = _members[uid];
    if (member != null) return member.fullName;
    if (_members.isEmpty && uid != ref.read(authProvider).user?.id) return _peerName;
    return null;
  }

  String _quoteSender(ReplyPreview q) => _nameFor(q.senderId) ?? 'Former member';

  void _startReply(Message m) {
    if (!m.canReply) return;
    if (_editing != null) _cancelEdit();
    setState(() => _replyingTo = ReplyPreview.of(m));
    HapticFeedback.selectionClick();
  }

  void _cancelReply() => setState(() => _replyingTo = null);

  /// Long-press: WhatsApp-style sheet — reaction tray on top, then every
  /// action that applies to this message.
  Future<void> _onLongPress(Message m) async {
    final me = ref.read(authProvider).user?.id;
    if (me == null) return;
    HapticFeedback.mediumImpact();
    final conv = _conv;
    final pinned = conv?.activePinnedMessageId() == m.id;
    final canPin = conv != null &&
        (conv.type != ConversationType.group || _isGroupAdmin || _groupId == null);
    final own = m.senderId == me && m.status == MessageStatus.sent;
    final actions = <MessageAction>[
      if (m.canReply) MessageAction.reply,
      if (m.canForward) MessageAction.forward,
      if (m.type == MessageType.text && !m.isDeleted && _allowCopy) MessageAction.copy,
      if (m.canStar) (m.starred ? MessageAction.unstar : MessageAction.star),
      if (m.canPin && canPin) (pinned ? MessageAction.unpin : MessageAction.pin),
      if (own && !m.isDeleted) MessageAction.info,
      if (m.canEdit(me: me)) MessageAction.edit,
      if (!m.isDeleted || own) MessageAction.delete,
      if (!own && !m.isDeleted && m.type != MessageType.system) MessageAction.report,
      MessageAction.select,
    ];
    final result = await showMessageContextMenu(
      context,
      actions: actions,
      reactable: m.canReact,
      currentReaction: m.myReaction(me),
    );
    if (!mounted || result == null) return;
    switch (result) {
      case ContextMenuReaction(:final emoji):
        if (emoji == null) {
          await _moreReactions(m.id);
        } else {
          await _react(m.id, emoji);
        }
      case ContextMenuAction(:final action):
        switch (action) {
          case MessageAction.reply:
            _startReply(m);
          case MessageAction.forward:
            await _forward([m]);
          case MessageAction.copy:
            await _copy(m);
          case MessageAction.star:
            await _star(m, true);
          case MessageAction.unstar:
            await _star(m, false);
          case MessageAction.pin:
            await _pin(m);
          case MessageAction.unpin:
            await _unpin();
          case MessageAction.info:
            showMessageReceiptsSheet(context: context, message: m);
          case MessageAction.edit:
            _startEdit(m);
          case MessageAction.delete:
            setState(() => _selected.add(m.id));
            await _deleteSelected();
          case MessageAction.report:
            await _report(m);
          case MessageAction.select:
            setState(() => _selected.add(m.id));
        }
    }
  }

  Future<void> _copy(Message m) async {
    final text = (m.content ?? '').replaceAllMapped(
      mentionTokenPattern,
      (x) => '@${_nameFor(x.group(1)!.toLowerCase()) ?? 'someone'}',
    );
    await ref.read(clipboardProvider).copy(text);
    _toast(Strings.chatCopied);
  }

  Future<void> _star(Message m, bool starred) async {
    try {
      await ref.read(messagesProvider(widget.conversationId).notifier).star(m.id, starred);
      _toast(starred ? Strings.chatStarredToast : Strings.chatUnstarredToast);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    }
  }

  Future<void> _pin(Message m) async {
    final picked = await showChoiceSheet<int>(
      context,
      title: Strings.chatPinTitle,
      subtitle: Strings.chatPinHint,
      options: kPinDurations,
      wire: (v) => '$v',
      value: 2592000,
      keyPrefix: 'pin',
      field: 'duration',
    );
    if (picked == null || !mounted) return;
    try {
      await ref
          .read(conversationsProvider.notifier)
          .pinMessage(widget.conversationId, m.id, picked.$1);
      _toast(Strings.chatPinnedToastMessage);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    }
  }

  Future<void> _unpin() async {
    try {
      await ref.read(conversationsProvider.notifier).unpinMessage(widget.conversationId);
      _toast(Strings.chatUnpinnedToastMessage);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    }
  }

  Future<void> _forward(List<Message> messages) async {
    final targets = await showForwardPicker(context, excludeConversationId: widget.conversationId);
    if (targets == null || targets.isEmpty || !mounted) return;
    try {
      final repo = ref.read(chatRepositoryProvider);
      final convIds = <String>[];
      for (final t in targets) {
        if (t.conversationId != null) {
          convIds.add(t.conversationId!);
        } else if (t.userId != null) {
          // A person without a chat yet: open (or reuse) the direct chat.
          final c = await repo.createConversation(
            type: ConversationType.direct,
            name: null,
            memberIds: [t.userId!],
          );
          convIds.add(c.id);
        }
      }
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .forward([for (final m in messages) m.id], convIds);
      unawaited(ref.read(conversationsProvider.notifier).refresh());
      _toast(Strings.chatForwardedToast);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    }
  }

  Future<void> _report(Message m) async {
    final report = await showReportMessageSheet(context);
    if (report == null || !mounted) return;
    // Context: this message and the few before it — ids only, never bodies.
    final all = ref.read(messagesProvider(widget.conversationId)).value ?? const <Message>[];
    final i = all.indexWhere((x) => x.id == m.id);
    final context5 = <String>[
      for (final x in (i < 0 ? [m] : all.skip(i).take(5)))
        if (x.status == MessageStatus.sent && x.type != MessageType.system) x.id,
    ];
    try {
      await ref.read(networkRepositoryProvider).report(
            subjectType: 'message',
            subjectId: m.id,
            reason: report.reason.wire,
            details: report.details,
            contextMessageIds: context5,
          );
      _toast(Strings.chatReportedToast);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    }
  }

  // ---- Batch 4: links / mentions -----------------------------------------

  Future<void> _openLink(String href) async {
    await confirmAndOpenExternal(context, url: href, opener: ref.read(urlOpenerProvider));
  }

  Future<void> _callNumber(String digits) async {
    await confirmAndOpenExternal(
      context,
      url: 'tel:$digits',
      opener: ref.read(urlOpenerProvider),
      isPhone: true,
    );
  }

  void _openProfile(String userId) {
    if (userId == ref.read(authProvider).user?.id) return;
    context.push(AppRoutes.person(userId));
  }

  void _updateMentionState() {
    final next = _groupId == null ? null : _input.activeMention();
    final changed = (next == null) != (_mentionActive == null) ||
        next?.query != _mentionActive?.query;
    if (changed) setState(() => _mentionActive = next);
  }

  void _pickMention(GroupMember m) {
    _input.insertMention(userId: m.userId, name: m.fullName);
    setState(() {
      _mentionActive = null;
      _hasText = true;
    });
    _saveDraftSoon(_input.text);
  }

  /// A restored draft carries `@[uuid]` tokens; turn them into chips once the
  /// member list is here.
  bool _draftMentionsRestored = false;
  void _restoreDraftMentions() {
    if (_draftMentionsRestored || _members.isEmpty) return;
    _draftMentionsRestored = true;
    if (!mentionTokenPattern.hasMatch(_input.text)) return;
    _input.setFromWire(_input.text, _nameFor);
  }

  void _updateComposerPreview(String value) {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      final urls = extractUrls(value);
      final first = urls.isEmpty ? null : urls.first;
      final next = first == _dismissedPreviewUrl ? null : first;
      if (next != _composerPreviewUrl) setState(() => _composerPreviewUrl = next);
    });
  }

  /// Formatting toolbar on text selection: Bold / Italic / Strike / Mono
  /// insert the WhatsApp markers around the selection.
  Widget _composerContextMenu(BuildContext context, EditableTextState state) {
    void wrap(String marker) {
      final v = _input.value;
      final r = wrapSelection(v.text, v.selection.start, v.selection.end, marker);
      _input.value = TextEditingValue(
        text: r.text,
        selection: TextSelection(baseOffset: r.start, extentOffset: r.end),
      );
      _onInputChanged(r.text);
      ContextMenuController.removeAny();
    }
    final items = [
      ...state.contextMenuButtonItems,
      ContextMenuButtonItem(label: Strings.chatFormatBold, onPressed: () => wrap('*')),
      ContextMenuButtonItem(label: Strings.chatFormatItalic, onPressed: () => wrap('_')),
      ContextMenuButtonItem(label: Strings.chatFormatStrike, onPressed: () => wrap('~')),
      ContextMenuButtonItem(label: Strings.chatFormatMono, onPressed: () => wrap('`')),
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  // ---- Batch 4: jumping, search, unread --------------------------------------

  GlobalKey _rowKey(String id) => _rowKeys.putIfAbsent(id, GlobalKey.new);

  void _highlight(String id) {
    _highlightTimer?.cancel();
    setState(() => _highlightId = id);
    _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted && _highlightId == id) setState(() => _highlightId = null);
    });
  }

  /// Bring [messageId] into view: load older pages until it is held, then
  /// step the list up until its row is built and ensureVisible can finish.
  Future<bool> _jumpTo(String messageId, {double alignment = 0.5, bool highlight = true}) async {
    if (_jumping) return false;
    _jumping = true;
    try {
      final notifier = ref.read(messagesProvider(widget.conversationId).notifier);
      if (!await notifier.ensureLoaded(messageId)) return false;
      if (!mounted) return false;
      for (var step = 0; step < 400; step++) {
        final ctx = _rowKey(messageId).currentContext;
        if (ctx != null && ctx.mounted) {
          await Scrollable.ensureVisible(
            ctx,
            alignment: alignment,
            duration: AppMotion.reduced(context) ? Duration.zero : AppMotion.micro,
          );
          if (highlight && mounted) _highlight(messageId);
          return true;
        }
        if (!_scroll.hasClients) return false;
        final pos = _scroll.position;
        if (pos.pixels >= pos.maxScrollExtent - 1) {
          // At the very top and still not built: one more frame for layout.
          await WidgetsBinding.instance.endOfFrame;
          if (_rowKey(messageId).currentContext == null) return false;
          continue;
        }
        _scroll.jumpTo((pos.pixels + pos.viewportDimension * 0.9).clamp(0, pos.maxScrollExtent));
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return false;
      }
      return false;
    } finally {
      _jumping = false;
    }
  }

  /// Work out where the "N unread" divider goes (oldest unread message) and
  /// scroll there. Runs once, after the first page is on screen.
  Future<void> _resolveUnread(List<Message> msgs, String? me) async {
    if (_unreadResolved) return;
    _unreadResolved = true;
    final n = _unreadAtOpen ?? 0;
    if (n <= 0 || me == null) return;
    final notifier = ref.read(messagesProvider(widget.conversationId).notifier);
    String? oldestUnread(List<Message> list) {
      var count = 0;
      for (final m in list) {
        if (m.senderId == me || m.type == MessageType.system || m.isDeleted) continue;
        count++;
        if (count == n) return m.id;
      }
      return null;
    }
    var id = oldestUnread(msgs);
    if (id == null) {
      await notifier.loadOlderWhile((loaded) => oldestUnread(loaded) == null);
      id = oldestUnread(ref.read(messagesProvider(widget.conversationId)).value ?? const []);
    }
    if (id == null || !mounted) return;
    setState(() => _unreadDividerId = id);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) await _jumpTo(id, alignment: 0.85, highlight: false);
  }

  void _enterSearch() {
    setState(() {
      _searching = true;
      _searchQuery = '';
      _hits = const [];
      _hitIndex = -1;
    });
    _searchInput.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  void _exitSearch() {
    _searchDebounce?.cancel();
    _searchFocus.unfocus();
    setState(() {
      _searching = false;
      _searchQuery = '';
      _hits = const [];
      _hitIndex = -1;
      _highlightId = null;
    });
  }

  static bool _matches(Message m, String q) {
    if (m.isDeleted || m.status != MessageStatus.sent) return false;
    final hay = switch (m.type) {
      MessageType.text => plainText(m.content ?? ''),
      MessageType.file => '${m.fileName ?? ''} ${m.caption ?? ''}',
      MessageType.voiceNote => '${m.transcript ?? ''} ${m.caption ?? ''}',
      MessageType.image || MessageType.video => m.caption ?? '',
      MessageType.poll => m.poll?.question ?? '',
      _ => '',
    };
    return hay.toLowerCase().contains(q);
  }

  List<String> _findHits(List<Message> msgs, String q) =>
      [for (final m in msgs) if (_matches(m, q)) m.id];

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () => _runSearch(value));
  }

  Future<void> _runSearch(String value) async {
    final q = value.trim().toLowerCase();
    if (!mounted) return;
    if (q.isEmpty) {
      setState(() {
        _searchQuery = '';
        _hits = const [];
        _hitIndex = -1;
      });
      return;
    }
    setState(() {
      _searchQuery = q;
      _searchBusy = true;
    });
    final notifier = ref.read(messagesProvider(widget.conversationId).notifier);
    var hits = _findHits(ref.read(messagesProvider(widget.conversationId)).value ?? const [], q);
    if (hits.isEmpty) {
      // Nothing on screen: pull older pages until a hit or history ends.
      await notifier.loadOlderWhile((loaded) => _findHits(loaded, q).isEmpty);
      hits = _findHits(ref.read(messagesProvider(widget.conversationId)).value ?? const [], q);
    }
    if (!mounted || _searchQuery != q) return;
    setState(() {
      _hits = hits;
      _hitIndex = hits.isEmpty ? -1 : 0;
      _searchBusy = false;
    });
    if (hits.isNotEmpty) await _jumpTo(hits.first);
  }

  /// Older hit (up arrow). Past the last loaded hit, pull more history.
  Future<void> _searchOlder() async {
    if (_searchQuery.isEmpty || _searchBusy) return;
    if (_hitIndex + 1 < _hits.length) {
      setState(() => _hitIndex++);
      await _jumpTo(_hits[_hitIndex]);
      return;
    }
    final notifier = ref.read(messagesProvider(widget.conversationId).notifier);
    if (!notifier.hasMore) return;
    setState(() => _searchBusy = true);
    final before = _hits.length;
    await notifier.loadOlderWhile(
      (loaded) => _findHits(loaded, _searchQuery).length <= before,
    );
    if (!mounted) return;
    final hits = _findHits(ref.read(messagesProvider(widget.conversationId)).value ?? const [], _searchQuery);
    setState(() {
      _hits = hits;
      _searchBusy = false;
      if (hits.length > before) _hitIndex = before;
    });
    if (hits.length > before) await _jumpTo(hits[before]);
  }

  Future<void> _searchNewer() async {
    if (_hitIndex <= 0) return;
    setState(() => _hitIndex--);
    await _jumpTo(_hits[_hitIndex]);
  }

  Future<void> _jumpToDate() async {
    final conv = _conv;
    final now = DateTime.now();
    final first = conv?.createdAt.toLocal() ?? now.subtract(const Duration(days: 365));
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(first.year, first.month, first.day),
      lastDate: now,
      helpText: Strings.chatJumpToDate.toUpperCase(),
    );
    if (picked == null || !mounted) return;
    final id = await ref
        .read(messagesProvider(widget.conversationId).notifier)
        .jumpToDate(DateTime.utc(picked.year, picked.month, picked.day));
    if (!mounted) return;
    if (id == null) {
      _toast(Strings.chatJumpToDateNone);
      return;
    }
    await _jumpTo(id);
  }

  /// Search-mode app bar: query field, hit counter, older / newer, calendar.
  PreferredSizeWidget _searchBar() {
    final counter = _searchQuery.isEmpty
        ? ''
        : _hits.isEmpty
            ? Strings.chatSearchNone
            : '${_hitIndex + 1}/${_hits.length}';
    return AppBar(
      leading: IconButton(
        key: const ValueKey('search-close'),
        icon: const Icon(Icons.arrow_back),
        onPressed: _exitSearch,
      ),
      titleSpacing: 0,
      title: TextField(
        key: const ValueKey('thread-search-field'),
        controller: _searchInput,
        focusNode: _searchFocus,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onTapOutside: (_) => _searchFocus.unfocus(),
        decoration: const InputDecoration(
          hintText: Strings.chatSearchHint,
          border: InputBorder.none,
          isDense: true,
        ),
        onChanged: _onSearchChanged,
        onSubmitted: (v) => _runSearch(v),
      ),
      actions: [
        if (_searchBusy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
          )
        else if (counter.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Center(child: Text(counter, key: const ValueKey('search-counter'), style: AppText.caption)),
          ),
        IconButton(
          key: const ValueKey('search-older'),
          tooltip: 'Older',
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
          onPressed: _searchQuery.isEmpty ? null : _searchOlder,
        ),
        IconButton(
          key: const ValueKey('search-newer'),
          tooltip: 'Newer',
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: _hitIndex > 0 ? _searchNewer : null,
        ),
        IconButton(
          key: const ValueKey('search-calendar'),
          tooltip: Strings.chatJumpToDate,
          icon: const Icon(Icons.calendar_month_outlined),
          onPressed: _jumpToDate,
        ),
      ],
    );
  }

  // ---- Scheduled send (long-press on the send button) ---------------------

  static const _deviceZone = 'Device time';
  // ponytail: curated zone list; the server (Python zoneinfo) accepts any
  // IANA name, so growing this is a one-line-per-zone change.
  static const _zones = [
    _deviceZone,
    'UTC',
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Los_Angeles',
    'Europe/London',
    'Europe/Berlin',
    'Asia/Dubai',
    'Asia/Kolkata',
    'Asia/Singapore',
    'Asia/Tokyo',
    'Australia/Sydney',
  ];

  Future<void> _openScheduleSheet() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    var when = DateTime.now().add(const Duration(hours: 1));
    var date = DateTime(when.year, when.month, when.day);
    var time = TimeOfDay.fromDateTime(when);
    var zone = _deviceZone;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Schedule message',
                  style: Theme.of(ctx).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                ListTile(
                  leading: const Icon(Icons.event, color: AppColors.medBlue),
                  title: Text(DateFormat.yMMMEd().format(date)),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setSheet(() => date = picked);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.schedule, color: AppColors.medBlue),
                  title: Text(time.format(ctx)),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: ctx,
                      initialTime: time,
                    );
                    if (picked != null) setSheet(() => time = picked);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.public, color: AppColors.medBlue),
                  title: DropdownButton<String>(
                    value: zone,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final z in _zones)
                        DropdownMenuItem(
                          value: z,
                          child: Text(z.replaceAll('_', ' ')),
                        ),
                    ],
                    onChanged: (z) {
                      if (z != null) setSheet(() => zone = z);
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Schedule'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final wall = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    // Device zone: the client already knows the UTC instant — send it as UTC.
    // Named zone: send the wall-clock time and let the server's tz database
    // resolve the instant (DST rules live in one place).
    final scheduledLocal = zone == _deviceZone
        ? wall.toUtc().toIso8601String()
        : DateFormat("yyyy-MM-dd'T'HH:mm:00").format(wall);
    final tz = zone == _deviceZone ? 'UTC' : zone;
    try {
      await ref
          .read(chatRepositoryProvider)
          .scheduleText(
            widget.conversationId,
            text,
            scheduledLocal: scheduledLocal,
            timezone: tz,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(e))));
      }
      return;
    }
    if (!mounted) return;
    _input.clear();
    setState(() => _hasText = false);
    _stopTyping();
    _draftSave?.cancel();
    unawaited(ref.read(draftsProvider.notifier).clear(widget.conversationId));
    final zoneLabel = zone == _deviceZone
        ? ''
        : ' (${zone.replaceAll('_', ' ')})';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Scheduled for ${DateFormat.yMMMEd().format(wall)} ${time.format(context)}$zoneLabel',
        ),
      ),
    );
  }

  // ---- Request-tier actions (recipient) -----------------------------------

  // ---- Attachments ---------------------------------------------------------

  Future<void> _pickAttachment() async {
    final choice = await _showOptionsSheet(
      title: 'Share',
      options: [
        (icon: Icons.photo_outlined, label: Strings.mediaPhotos, value: 'photo'),
        (icon: Icons.videocam_outlined, label: Strings.mediaVideo, value: 'video'),
        (icon: Icons.description_outlined, label: Strings.mediaDocument, value: 'doc'),
        if (Platform.isIOS)
          (icon: Icons.document_scanner_outlined, label: Strings.mediaScanDocument, value: 'scan')
        else
          (icon: Icons.camera_alt_outlined, label: Strings.mediaTakePhoto, value: 'camera'),
        (icon: Icons.poll_outlined, label: Strings.mediaPoll, value: 'poll'),
      ],
    );
    switch (choice) {
      case 'photo':
        await _pickPhoto();
      case 'video':
        await _pickVideo();
      case 'doc':
        await _pickDocument();
      case 'scan':
        await _scanDocument();
      case 'camera':
        await _pickPhoto(cameraOnly: true);
      case 'poll':
        await _createPoll();
    }
  }

  /// Photos (batch 5 B): camera → one; library → up to 30, each its own
  /// message, grouped into an album by the thread. Pixels are capped by the
  /// upload-quality setting, EXIF (GPS, device) is stripped on the phone,
  /// and the caption rides on the last photo.
  Future<void> _pickPhoto({bool cameraOnly = false}) async {
    final source = cameraOnly
        ? 'camera'
        : await _showOptionsSheet(
            title: Strings.mediaPhotos,
            options: const [
              (icon: Icons.camera_alt_outlined, label: Strings.mediaTakePhoto, value: 'camera'),
              (icon: Icons.photo_library_outlined, label: Strings.mediaChooseGallery, value: 'gallery'),
            ],
          );
    if (source == null) return;
    final quality = ref.read(mediaSettingsProvider).uploadQuality;
    final maxSide = quality.maxSide?.toDouble();
    final picker = ImagePicker();
    List<XFile> picked;
    try {
      if (source == 'camera') {
        final x = await picker.pickImage(
          source: ImageSource.camera,
          maxWidth: maxSide,
          maxHeight: maxSide,
          imageQuality: maxSide == null ? null : 85,
        );
        picked = [?x];
      } else {
        picked = await picker.pickMultiImage(
          maxWidth: maxSide,
          maxHeight: maxSide,
          imageQuality: maxSide == null ? null : 85,
          limit: MediaLimits.multiPhotoMax,
        );
      }
    } catch (_) {
      _showError(source == 'camera' ? 'Camera not available on this device' : 'Could not open the photo library');
      return;
    }
    if (picked.isEmpty || !mounted) return;
    if (picked.length > MediaLimits.multiPhotoMax) {
      _showError(Strings.mediaTooManyPhotos);
      picked = picked.sublist(0, MediaLimits.multiPhotoMax);
    }
    final caption = await showCaptionSheet(
      context,
      previews: [for (final x in picked) CaptionPreview(imagePath: x.path, label: Strings.mediaPhoto)],
    );
    if (caption == null || !mounted) return;
    await sendPhotoFiles([for (final x in picked) (path: x.path, name: x.name, mime: x.mimeType)], caption: caption);
  }

  /// Shared by the picker and the integration test hook: strip EXIF, send
  /// each photo as its own message, caption on the last.
  @visibleForTesting
  Future<void> sendPhotoFiles(List<({String path, String name, String? mime})> files, {String? caption}) async {
    for (final (i, x) in files.indexed) {
      final raw = await File(x.path).readAsBytes();
      final bytes = ImageMetadata.strip(raw);
      await _upload(
        bytes: bytes,
        filename: x.name,
        contentType: x.mime ?? lookupMimeType(x.name) ?? 'image/jpeg',
        caption: i == files.length - 1 && (caption ?? '').isNotEmpty ? caption : null,
      );
    }
  }

  /// Video (batch 5 C): record or pick, ≤ 10 min / 100 MB, poster made on
  /// the phone, presigned upload with progress in the bubble.
  Future<void> _pickVideo() async {
    final source = await _showOptionsSheet(
      title: Strings.mediaVideo,
      options: const [
        (icon: Icons.videocam_outlined, label: Strings.mediaRecordVideo, value: 'camera'),
        (icon: Icons.video_library_outlined, label: Strings.mediaChooseGallery, value: 'gallery'),
      ],
    );
    if (source == null) return;
    XFile? picked;
    try {
      picked = await ImagePicker().pickVideo(
        source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxDuration: MediaLimits.videoMaxDuration,
      );
    } catch (_) {
      _showError(source == 'camera' ? 'Camera not available on this device' : 'Could not open the photo library');
      return;
    }
    if (picked == null || !mounted) return;
    await sendVideoFile(picked.path, fileName: picked.name, contentType: picked.mimeType);
  }

  /// Shared by the picker and the integration test hook: caption, limits,
  /// then the notifier's outbox-first send.
  @visibleForTesting
  Future<void> sendVideoFile(String path, {required String fileName, String? contentType, bool askCaption = true, String? caption}) async {
    if (await File(path).length() > MediaLimits.videoMaxBytes) {
      _showError(Strings.mediaVideoTooLarge);
      return;
    }
    if (!mounted) return;
    if (askCaption) {
      caption = await showCaptionSheet(
        context,
        previews: [CaptionPreview(icon: Icons.videocam_outlined, label: Strings.mediaVideo)],
      );
      if (caption == null || !mounted) return;
    }
    try {
      final ok = await ref.read(messagesProvider(widget.conversationId).notifier).sendVideo(
            sourcePath: path,
            fileName: fileName,
            contentType: contentType ?? lookupMimeType(fileName) ?? 'video/mp4',
            caption: caption != null && caption.isNotEmpty ? caption : null,
          );
      if (!ok) _showError(Strings.mediaVideoTooLong);
    } catch (e) {
      _showError(ErrorMessages.forApi(e));
    }
  }

  /// Documents up to 100 MB go by path (presigned parts above 8 MB) — never
  /// through Dart memory.
  Future<void> _pickDocument() async {
    final result = await FilePicker.platform.pickFiles(withData: false);
    final file = result?.files.firstOrNull;
    if (file == null || file.path == null || !mounted) return;
    if (file.size > MediaLimits.fileMaxBytes) {
      _showError(Strings.mediaFileTooLarge);
      return;
    }
    final caption = await showCaptionSheet(
      context,
      previews: [CaptionPreview(label: file.name)],
    );
    if (caption == null || !mounted) return;
    try {
      await ref.read(messagesProvider(widget.conversationId).notifier).sendFilePath(
            sourcePath: file.path!,
            fileName: file.name,
            contentType: lookupMimeType(file.name) ?? 'application/octet-stream',
            caption: caption.isNotEmpty ? caption : null,
          );
    } catch (e) {
      _showError(ErrorMessages.forApi(e));
    }
  }

  /// VisionKit scanner → PDF (batch 5 H). iOS only; Android offers the
  /// camera instead (see [_pickAttachment]).
  Future<void> _scanDocument() async {
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/scan_${DateTime.now().millisecondsSinceEpoch}.pdf';
    final ok = await ref.read(mediaNativeProvider).scanDocument(out);
    if (!mounted) return;
    if (ok == null) {
      _showError(Strings.mediaScanUnavailable);
      return;
    }
    if (!ok) return; // user backed out
    final name = 'Scan ${DateFormat('yyyy-MM-dd HH.mm').format(DateTime.now())}.pdf';
    final caption = await showCaptionSheet(context, previews: [CaptionPreview(icon: Icons.document_scanner_outlined, label: name)]);
    if (caption == null || !mounted) return;
    try {
      await ref.read(messagesProvider(widget.conversationId).notifier).sendFilePath(
            sourcePath: out,
            fileName: name,
            contentType: 'application/pdf',
            caption: caption.isNotEmpty ? caption : null,
          );
    } catch (e) {
      _showError(ErrorMessages.forApi(e));
    }
  }

  Future<void> _createPoll() async {
    final draft = await showPollCreateSheet(context);
    if (draft == null || !mounted) return;
    try {
      await ref.read(messagesProvider(widget.conversationId).notifier).sendPoll(
            question: draft.question,
            options: draft.options,
            multiple: draft.multiple,
            replyTo: _replyingTo,
          );
      if (_replyingTo != null) setState(() => _replyingTo = null);
    } catch (e) {
      _showError(ErrorMessages.forApi(e));
    }
  }

  Future<void> _vote(Message m, List<String> optionIds) async {
    try {
      await ref.read(messagesProvider(widget.conversationId).notifier).vote(m.id, optionIds);
    } catch (e) {
      _showError(ErrorMessages.forApi(e));
    }
  }

  void _showPollVoters(Message m) {
    final poll = m.poll;
    if (poll == null) return;
    showPollVotersSheet(
      context: context,
      poll: poll,
      nameFor: (uid) => _nameFor(uid) ?? 'Former member',
      colorFor: (uid) => _members[uid]?.avatarIndex ?? 0,
    );
  }

  /// Every photo and video of the thread in send order, opened at [m].
  void _openViewer(Message m) {
    final msgs = ref.read(messagesProvider(widget.conversationId)).asData?.value ?? const <Message>[];
    final items = [
      for (final x in msgs.reversed)
        if ((x.type == MessageType.image || x.type == MessageType.video) && !x.isDeleted && x.status == MessageStatus.sent) x,
    ];
    final index = items.indexWhere((x) => x.id == m.id);
    MediaViewerScreen.open(
      context,
      conversationId: widget.conversationId,
      items: index < 0 ? [m] : items,
      initialIndex: index < 0 ? 0 : index,
    );
  }

  Future<String> _fileUrl(Message m) => ref.read(chatRepositoryProvider).fileUrl(m.id);
  Future<String> _thumbUrl(Message m) => ref.read(chatRepositoryProvider).fileUrl(m.id, thumb: true);

  Future<({String path, bool isFile})> _voiceSource(Message m) =>
      resolveVoiceSource(ref, m, url: () => _fileUrl(m), download: true);

  bool _autoFor(MediaDownloadKind kind) => _auto[kind] ?? (kind == MediaDownloadKind.photos);

  Future<void> _resolveAutoDownload() async {
    for (final kind in MediaDownloadKind.values) {
      final allowed = await shouldAutoDownload(ref, kind);
      if (!mounted) return;
      if (_auto[kind] != allowed) setState(() => _auto[kind] = allowed);
    }
  }

  // ---- Hold-to-record pointer handling (batch 5 D) ------------------------

  bool _micHit(Offset global) {
    final box = _micKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final local = box.globalToLocal(global);
    return (Offset.zero & box.size).contains(local);
  }

  void _onComposerPointerDown(PointerDownEvent e) {
    if (_showRecorder || !_micHit(e.position)) return;
    _micDown = e.position;
    _holdTimer?.cancel();
    _holdTimer = Timer(_holdDelay, () {
      if (!mounted || _micDown == null) return;
      _holding = true;
      HapticFeedback.mediumImpact();
      setState(() {
        _showRecorder = true;
        _recorderHeld = true;
      });
    });
  }

  void _onComposerPointerMove(PointerMoveEvent e) {
    final down = _micDown;
    if (down == null) return;
    final d = e.position - down;
    if (!_holding) {
      // Moved before the hold kicked in: a scroll or a slip, not a hold.
      if (d.distance > 12) {
        _holdTimer?.cancel();
        _micDown = null;
      }
      return;
    }
    final panel = _recorderKey.currentState;
    panel?.setSlide(d.dx);
    if (d.dx < VoiceRecorderPanel.cancelDx) {
      _endHold();
      panel?.cancelHold();
    } else if (d.dy < VoiceRecorderPanel.lockDy) {
      _endHold();
      panel?.lock();
    }
  }

  void _onComposerPointerUp(PointerEvent e) {
    if (_micDown == null) return;
    if (!_holding) {
      // A tap: the classic stop-review-send panel.
      _holdTimer?.cancel();
      _micDown = null;
      if (e is PointerUpEvent) {
        setState(() {
          _showRecorder = true;
          _recorderHeld = false;
        });
      }
      return;
    }
    _endHold();
    final panel = _recorderKey.currentState;
    if (panel != null) {
      panel.releaseHold();
    } else {
      // Let go before the panel's first frame: finish once it exists.
      WidgetsBinding.instance.addPostFrameCallback((_) => _recorderKey.currentState?.releaseHold());
    }
  }

  void _endHold() {
    _holding = false;
    _micDown = null;
    _holdTimer?.cancel();
  }

  void _closeRecorder() {
    _endHold();
    if (!mounted) return;
    setState(() {
      _showRecorder = false;
      _recorderHeld = false;
    });
  }

  /// Outbox-first: the notifier persists + enqueues and shows an optimistic
  /// bubble immediately; failures surface as a failed bubble (tap to retry),
  /// so no blocking spinner and no error snackbar here.
  Future<void> _upload({
    required List<int> bytes,
    required String filename,
    required String contentType,
    String? caption,
  }) async {
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .sendUpload(
            bytes: bytes,
            filename: filename,
            contentType: contentType,
            caption: caption,
          );
    } catch (e) {
      // Only local persistence can throw (e.g. disk full).
      _showError(ErrorMessages.forApi(e));
    }
  }

  Future<String?> _showOptionsSheet({
    required String title,
    required List<({IconData icon, String label, String value})> options,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Text(title, style: AppText.heading),
            ),
            for (final o in options)
              ListTile(
                leading: Icon(o.icon, color: AppColors.medBlue),
                title: Text(o.label, style: AppText.bodyPrimary),
                onTap: () => Navigator.of(sheetCtx).pop(o.value),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- Entrance / separator helpers ---------------------------------------

  /// Records which message ids are already known so only genuinely NEW
  /// messages (arrived over WS after mount) get an entrance animation.
  /// History and older pagination pages never animate. Runs during build —
  /// pure set mutation, no setState (the unseen-count bump is deferred).
  void _trackNew(List<Message> msgs, String? meId) {
    if (!_seededIds) {
      _knownIds.addAll(msgs.map((m) => m.id));
      _seededIds = true;
      return;
    }
    var newIncoming = 0;
    for (final m in msgs) {
      if (_knownIds.contains(m.id)) continue;
      _knownIds.add(m.id);
      // Server echo of an optimistic outbox bubble: same message, new id —
      // it already animated under its clientId, don't replay. (The optimistic
      // bubble itself has id == clientId, so exclude that case.)
      final isEcho =
          m.clientId != null &&
          m.clientId != m.id &&
          _knownIds.contains(m.clientId);
      if (m.createdAt.isAfter(_openedAt) && !isEcho) {
        _entranceIds.add(m.id);
        if (m.senderId != meId) newIncoming++;
      }
    }
    if (newIncoming > 0 &&
        _scroll.hasClients &&
        _scroll.position.pixels > _jumpThresholdPx) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _unseenCount += newIncoming);
      });
    }
  }

  /// Consecutive same-sender, same-day bubbles group tighter.
  /// List is reversed: the message visually above index i is msgs[i + 1].
  bool _isGrouped(List<Message> msgs, int i) {
    if (i + 1 >= msgs.length) return false;
    final prev = msgs[i + 1];
    final cur = msgs[i];
    return prev.senderId == cur.senderId &&
        prev.type != MessageType.system &&
        _sameDay(prev.createdAt.toLocal(), cur.createdAt.toLocal());
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dayLabel(DateTime local) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(local.year, local.month, local.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return DateFormat(
      that.year == now.year ? 'MMM d' : 'MMM d, y',
    ).format(that);
  }

  /// Per-type bubble (logic unchanged from the pre-revamp itemBuilder);
  /// failed bubbles get press feedback via AppPressable but keep the exact
  /// same tap → retry/discard sheet flow.
  /// In a group, who sent what: user id → member. Empty in a 1:1 chat.
  Map<String, GroupMember> _members = const {};

  /// 1:1 chats have no member list; the header title names the peer.
  String? _peerName;

  /// "Dr Ravi Patel, Dr Sarah Kim, You": the header's member line.
  static String _memberLine(List<GroupMember> members, String? meId) {
    final others = [
      for (final m in members)
        if (m.userId != meId) m.fullName,
    ];
    return [
      ...others,
      if (members.any((m) => m.userId == meId)) 'You',
    ].join(', ');
  }

  Widget _buildBubble(Message m, bool isMine, List<Message> msgs, int i) {
    if (m.type == MessageType.system) {
      return SystemMessageBubble(text: m.content ?? '');
    }
    final grouped = _isGrouped(msgs, i);
    // Groups name the sender above the first bubble of each run, like
    // WhatsApp. Text bubbles carry it inside; media gets a label above.
    final sender = isMine || grouped ? null : _members[m.senderId];
    // Sender deleted it: same tombstone for every type, no menu, no ticks.
    if (m.isDeleted) {
      return MessageBubble(
        text: '',
        isMine: isMine,
        timestamp: m.createdAt.toLocal(),
        grouped: grouped,
        deleted: true,
        senderName: sender?.fullName,
        senderColorIndex: sender?.avatarIndex ?? 0,
      );
    }
    final bubble = _buildLiveBubble(m, isMine, msgs, i, grouped, sender);
    if (sender == null || m.type == MessageType.text) return bubble;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.screenHorizontal + AppSpacing.xs,
            bottom: 2,
          ),
          child: Text(
            sender.fullName,
            style: AppText.timestamp.copyWith(
              color: AppColors.avatarColorFor(sender.avatarIndex),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        bubble,
      ],
    );
  }

  /// Any non-system row: long-press starts selection, taps toggle while
  /// selecting (the bubble's own taps are swallowed, like WhatsApp), and the
  /// whole row tints when selected.
  ///
  /// Reactions: with exactly one reactable message selected, the reaction
  /// tray sits above it; reaction pills hang under any bubble that has them.
  Widget _selectable(Message m, Widget row) {
    if (m.type == MessageType.system) return row;
    final selected = _selected.contains(m.id);
    final me = ref.read(authProvider).user?.id;
    final isMine = m.senderId == me;
    final side = isMine ? Alignment.centerRight : Alignment.centerLeft;
    const inset = EdgeInsets.symmetric(
      horizontal: AppSpacing.screenHorizontal + AppSpacing.sm,
    );
    Widget content = AbsorbPointer(absorbing: _selecting, child: row);
    if (_unreadDividerId == m.id) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [UnreadDivider(count: _unreadAtOpen ?? 0), content],
      );
    }
    if (m.reactions.isNotEmpty && !m.isDeleted) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          Align(
            alignment: side,
            child: Transform.translate(
              offset: const Offset(0, -6),
              child: Padding(
                padding: inset,
                child: AbsorbPointer(
                  absorbing: _selecting,
                  child: ReactionPills(
                    reactions: m.reactions,
                    me: me,
                    onTap: () => _showWhoReacted(m.id),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    final highlighted = _highlightId == m.id;
    return SwipeToReply(
      enabled: !_selecting && !m.isDeleted,
      onReply: m.canReply ? () => _startReply(m) : null,
      child: GestureDetector(
        key: _rowKey(m.id),
        behavior: HitTestBehavior.opaque,
        onLongPress: _selecting ? null : () => _onLongPress(m),
        onTap: _selecting ? () => _toggleSelect(m) : null,
        child: AnimatedContainer(
          duration: AppMotion.maybe(context, AppMotion.base),
          color: selected
              ? AppColors.medBlue.withValues(alpha: 0.18)
              : highlighted
                  ? AppColors.amber.withValues(alpha: 0.18)
                  : Colors.transparent,
          child: content,
        ),
      ),
    );
  }

  Message? _messageById(String id) =>
      (ref.read(messagesProvider(widget.conversationId)).value ?? const <Message>[])
          .where((m) => m.id == id)
          .firstOrNull;

  /// Tray / picker pick: the same emoji as mine removes it, anything else
  /// sets it. Selection clears first, like WhatsApp.
  Future<void> _react(String messageId, String emoji) async {
    final me = ref.read(authProvider).user?.id;
    final m = _messageById(messageId);
    if (me == null || m == null) return;
    _clearSelection();
    await _sendReaction(messageId, m.myReaction(me) == emoji ? null : emoji);
  }

  Future<void> _sendReaction(String messageId, String? emoji) async {
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .react(messageId, emoji);
    } catch (e) {
      _toast(_reactionError(e));
    }
  }

  static String _reactionError(Object e) {
    if (e is ApiException) {
      if (e.detail == 'message_deleted') return 'Message was deleted';
      if (e.status == 429) return 'Slow down a little';
      return ErrorMessages.forApi(e);
    }
    return 'Couldn\'t react. Check your connection.';
  }

  Future<void> _moreReactions(String messageId) async {
    _clearSelection();
    final picked = await showEmojiPickerSheet(
      context,
      ref.read(chatCacheProvider),
    );
    if (!mounted || picked == null) return;
    await _react(messageId, picked);
  }

  void _showWhoReacted(String messageId) {
    final m = _messageById(messageId);
    if (m == null || m.reactions.isEmpty) return;
    showWhoReactedSheet(
      context: context,
      reactions: m.reactions,
      me: ref.read(authProvider).user?.id,
      nameFor: (uid) => _members[uid]?.fullName ?? _peerName ?? 'Former member',
      colorFor: (uid) => _members[uid]?.avatarIndex ?? 0,
      onRemoveMine: () => _sendReaction(messageId, null),
    );
  }

  Widget _buildLiveBubble(
    Message m,
    bool isMine,
    List<Message> msgs,
    int i,
    bool grouped,
    GroupMember? sender,
  ) {
    // Local outbox media/voice (sending or failed): the file isn't on the
    // server yet, so the URL-backed bubbles can't render it — show a labeled
    // bubble with status ticks (and the same tap-to-retry flow as failed text).
    final isLocalPending = m.clientId != null && m.status != MessageStatus.sent;
    if (isLocalPending && m.type != MessageType.text) {
      final Widget bubble;
      final progress = ref.watch(uploadProgressProvider.select((p) => p[m.clientId]));
      if (m.type == MessageType.image && m.localPath != null) {
        bubble = PendingImageBubble(
          path: m.localPath!,
          isMine: isMine,
          timestamp: m.createdAt.toLocal(),
          status: m.status,
          caption: m.caption,
          progress: progress,
        );
      } else if (m.type == MessageType.video) {
        bubble = PendingVideoBubble(
          posterPath: m.localThumbPath,
          durationSec: m.voiceDurationSec ?? 0,
          isMine: isMine,
          timestamp: m.createdAt.toLocal(),
          status: m.status,
          caption: m.caption,
          progress: progress,
          width: m.mediaWidth,
          height: m.mediaHeight,
        );
      } else if (m.type == MessageType.file) {
        bubble = FileBubble(
          getFileUrl: null, // still local — nothing to open yet
          fileName: m.fileName ?? 'Document',
          fileSizeBytes: m.fileSizeBytes,
          isMine: isMine,
          timestamp: m.createdAt.toLocal(),
          status: m.status,
          caption: m.caption,
          progress: progress,
        );
      } else if (m.type == MessageType.voiceNote) {
        bubble = VoiceNoteBubble(
          messageId: m.id,
          conversationId: widget.conversationId,
          durationSec: m.voiceDurationSec ?? 0,
          transcript: m.transcript,
          caption: m.caption,
          waveform: m.waveform,
          isMine: isMine,
          timestamp: m.createdAt.toLocal(),
          status: m.status,
        );
      } else {
        final label = m.fileName ?? 'Attachment';
        bubble = MessageBubble(
          text: label,
          isMine: isMine,
          timestamp: m.createdAt.toLocal(),
          read: m.read,
          delivered: m.delivered,
          status: m.status,
          grouped: grouped,
        );
      }
      if (m.status == MessageStatus.failed) {
        return AppPressable(
          onTap: () => _onFailedTap(m.clientId!),
          child: bubble,
        );
      }
      return bubble;
    }
    if (m.type != MessageType.text) {
      return _decorateMedia(m, isMine, _buildMediaBubble(m, isMine));
    }
    return _buildTextBubble(m, isMine, grouped, sender);
  }

  static String? _forwardedLabel(Message m) => !m.forwarded
      ? null
      : m.forwardedManyTimes
          ? Strings.chatForwardedManyTimes
          : Strings.chatForwarded;

  /// Media bubbles don't know about quotes / forwards / stars: the label goes
  /// above and the star sits in the corner.
  Widget _decorateMedia(Message m, bool isMine, Widget bubble) {
    final label = _forwardedLabel(m);
    if (label == null && !m.starred && m.replyTo == null) return bubble;
    final side = isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Column(
      crossAxisAlignment: side,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg + AppSpacing.xs, AppSpacing.xs, AppSpacing.lg + AppSpacing.xs, 0),
            child: Row(
              key: const ValueKey('forwarded-label'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shortcut_rounded, size: 13, color: AppColors.textMuted),
                const SizedBox(width: 3),
                Text(label, style: AppText.timestamp.copyWith(color: AppColors.textMuted, fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        if (m.replyTo != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.72),
              child: QuoteStrip(
                quote: m.replyTo,
                senderName: _quoteSender(m.replyTo!),
                isMine: false,
                nameFor: _nameFor,
                onTap: () => _jumpTo(m.replyTo!.id),
              ),
            ),
          ),
        Stack(
          children: [
            bubble,
            if (m.starred)
              Positioned(
                right: isMine ? AppSpacing.lg + 4 : null,
                left: isMine ? null : AppSpacing.lg + 4,
                top: AppSpacing.sm,
                child: const Icon(Icons.star_rounded, key: ValueKey('bubble-star'), size: 14, color: AppColors.amber),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildMediaBubble(Message m, bool isMine) {
    // Key by message id: these bubbles keep files / players in State —
    // without a key, ListView reuses the State for a DIFFERENT message when
    // the list shifts, showing the wrong media.
    switch (m.type) {
      case MessageType.voiceNote:
        return VoiceNoteBubble(
          key: ValueKey(m.id),
          messageId: m.id,
          conversationId: widget.conversationId,
          durationSec: m.voiceDurationSec ?? 0,
          transcript: m.transcript,
          caption: m.caption,
          waveform: m.waveform,
          isMine: isMine,
          timestamp: m.createdAt.toLocal(),
          read: m.read,
          delivered: m.delivered,
          resolve: () => _voiceSource(m),
        );
      case MessageType.image:
        return ImageBubble(
          key: ValueKey(m.id),
          messageId: m.id,
          conversationId: widget.conversationId,
          getFileUrl: () => _fileUrl(m),
          isMine: isMine,
          timestamp: m.createdAt.toLocal(),
          read: m.read,
          delivered: m.delivered,
          caption: m.caption,
          width: m.mediaWidth,
          height: m.mediaHeight,
          autoDownload: _autoFor(MediaDownloadKind.photos),
          onOpen: (_) => _openViewer(m),
        );
      case MessageType.video:
        return VideoBubble(
          key: ValueKey(m.id),
          messageId: m.id,
          conversationId: widget.conversationId,
          getFileUrl: () => _fileUrl(m),
          getThumbUrl: () => _thumbUrl(m),
          durationSec: m.voiceDurationSec ?? 0,
          isMine: isMine,
          timestamp: m.createdAt.toLocal(),
          read: m.read,
          delivered: m.delivered,
          caption: m.caption,
          width: m.mediaWidth,
          height: m.mediaHeight,
          autoDownload: _autoFor(MediaDownloadKind.video),
          onOpen: () => _openViewer(m),
        );
      case MessageType.poll:
        return PollBubble(
          key: ValueKey(m.id),
          message: m,
          poll: m.poll ?? const PollData(question: '', options: [], multiple: false),
          isMine: isMine,
          me: ref.read(authProvider).user?.id,
          onVote: (ids) => _vote(m, ids),
          onViewVotes: () => _showPollVoters(m),
        );
      default:
        return FileBubble(
          key: ValueKey(m.id),
          messageId: m.id,
          conversationId: widget.conversationId,
          getFileUrl: () => _fileUrl(m),
          fileName: m.fileName ?? 'File',
          fileSizeBytes: m.fileSizeBytes,
          isMine: isMine,
          timestamp: m.createdAt.toLocal(),
          read: m.read,
          delivered: m.delivered,
          caption: m.caption,
          prefetch: _autoFor(MediaDownloadKind.documents),
        );
    }
  }

  /// Album row (batch 5 B): the newest photo stands for the row (keys,
  /// selection, timestamp); the sender label follows the oldest like any
  /// other bubble.
  Widget _buildAlbum(ThreadRow r, bool isMine, List<Message> msgs, int iOld) {
    final m = r.first;
    final grouped = _isGrouped(msgs, iOld);
    final sender = isMine || grouped ? null : _members[m.senderId];
    final bubble = AlbumBubble(
      key: ValueKey('album-${r.id}'),
      messages: r.messages,
      conversationId: widget.conversationId,
      isMine: isMine,
      resolveUrl: _fileUrl,
      autoDownload: _autoFor(MediaDownloadKind.photos),
      onOpen: (i) => _openViewer(r.messages.reversed.elementAt(i)),
    );
    final decorated = Stack(
      children: [
        bubble,
        if (r.messages.any((x) => x.starred))
          Positioned(
            right: isMine ? AppSpacing.lg + 4 : null,
            left: isMine ? null : AppSpacing.lg + 4,
            top: AppSpacing.sm,
            child: const Icon(Icons.star_rounded, key: ValueKey('bubble-star'), size: 14, color: AppColors.amber),
          ),
      ],
    );
    if (sender == null) return decorated;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: AppSpacing.screenHorizontal + AppSpacing.xs, bottom: 2),
          child: Text(
            sender.fullName,
            style: AppText.timestamp.copyWith(color: AppColors.avatarColorFor(sender.avatarIndex), fontWeight: FontWeight.w600),
          ),
        ),
        decorated,
      ],
    );
  }

  Widget _buildTextBubble(Message m, bool isMine, bool grouped, GroupMember? sender) {
    final content = m.content ?? '[${m.type.wire}]';
    final urls = extractUrls(content);
    final showPreview = urls.isNotEmpty && ref.watch(linkPreviewsEnabledProvider);
    final bubble = MessageBubble(
      text: content,
      isMine: isMine,
      timestamp: m.createdAt.toLocal(),
      read: m.read,
      delivered: m.delivered,
      status: m.status,
      grouped: grouped,
      edited: m.editedAt != null,
      onEditedTap: () => _showEditHistory(m),
      senderName: sender?.fullName,
      senderColorIndex: sender?.avatarIndex ?? 0,
      body: MessageText(
        text: content,
        style: messageBodyStyle(isMine: isMine),
        isMine: isMine,
        nameFor: _nameFor,
        onMentionTap: _openProfile,
        onLinkTap: _openLink,
        onPhoneTap: _callNumber,
        highlight: _searching ? _searchQuery : null,
      ),
      quote: m.replyTo,
      quoteSenderName: m.replyTo == null ? null : _quoteSender(m.replyTo!),
      onQuoteTap: m.replyToId == null ? null : () => _jumpTo(m.replyToId!),
      nameFor: _nameFor,
      forwardedLabel: _forwardedLabel(m),
      starred: m.starred,
      highlighted: _highlightId == m.id,
      footer: showPreview
          ? LinkPreviewCard(
              url: urls.first,
              isMine: isMine,
              width: MediaQuery.sizeOf(context).width * 0.72 - AppSpacing.md * 2,
              onTap: () => _openLink(urls.first),
            )
          : null,
    );
    if (m.status == MessageStatus.failed && m.clientId != null) {
      return AppPressable(
        onTap: () => _onFailedTap(m.clientId!),
        child: bubble,
      );
    }
    return bubble;
  }

  void _jumpToBottom() {
    setState(() => _unseenCount = 0);
    if (AppMotion.reduced(context)) {
      _scroll.jumpTo(0);
    } else {
      _scroll.animateTo(
        0,
        duration: AppMotion.emphasizedDuration,
        curve: AppMotion.standard,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider).user;
    final async = ref.watch(messagesProvider(widget.conversationId));
    final otherTyping = ref.watch(typingProvider(widget.conversationId));
    // While the thread is open, mark read only when a genuinely NEW message
    // from the other party arrives (newest id changed) — guarding against the
    // read→MESSAGE_READ→rebuild feedback loop.
    ref.listen(messagesProvider(widget.conversationId), (prev, next) {
      final msgs = next.asData?.value;
      if (msgs == null || msgs.isEmpty) return;
      final prevNewestId = prev?.asData?.value.firstOrNull?.id;
      if (msgs.first.id == prevNewestId) {
        return; // read-state change, not a new message
      }
      if (msgs.first.senderId != me?.id) _markReadIfVisible();
    });
    // Back on top after a pushed screen (photo viewer, info) pops: settle a
    // read owed while it covered the chat. ModalRoute.of in _visible makes
    // this build re-run when the route's isCurrent changes.
    if (_readOwed && _visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_readOwed) _markReadIfVisible();
      });
    }
    final focused = ref.watch(conversationsProvider).asData?.value ?? const [];
    Conversation? conv;
    for (final c in focused) {
      if (c.id == widget.conversationId) {
        conv = c;
        break;
      }
    }
    final currentOrg = ref.watch(orgProvider).current;
    final orgMembers = currentOrg == null
        ? const <OrgMember>[]
        : (ref.watch(orgMembersProvider(currentOrg.id)).asData?.value ??
              const <OrgMember>[]);
    final display = conv == null
        ? null
        : conversationDisplay(
            c: conv,
            orgMembers: orgMembers,
            meId: me?.id,
            fallbackColorIndex: 0,
          );

    // A group thread: members name the senders and fill the subtitle, and the
    // header opens Group info instead of chat details.
    final groupId = widget.groupId ?? conv?.groupId;
    final members = groupId == null
        ? const <GroupMember>[]
        : (ref.watch(groupMembersProvider(groupId)).asData?.value ??
              const <GroupMember>[]);
    // Admins-only posting: members see a notice where the composer was. A
    // legacy org group (no groups row) has no detail → composer as always.
    final group = groupId == null
        ? null
        : ref.watch(groupDetailProvider(groupId)).asData?.value;
    final postingClosed =
        group != null && group.isMember && !group.canPost;
    _members = {for (final m in members) m.userId: m};
    _peerName = groupId == null ? display?.title : null;
    _restoreDraftMentions();
    // Pin banner: the shared pinned message, when the pin hasn't lapsed.
    final pinnedId = conv?.activePinnedMessageId();
    final pinnedMsg = pinnedId == null
        ? null
        : (async.asData?.value ?? const <Message>[]).where((m) => m.id == pinnedId).firstOrNull;
    final canUnpin = conv != null &&
        (conv.type != ConversationType.group || conv.groupId == null || (group?.canManage ?? false));
    // Direct chat: "online" or "last seen …" under the name, from what the
    // peer's privacy settings let me see (nothing → no line at all).
    final peerId = groupId == null && conv != null
        ? directPeerId(conv, me?.id)
        : null;
    final peerPresence =
        peerId == null ? null : ref.watch(presenceOfProvider(peerId));
    if (peerId != null && peerPresence == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(presenceProvider.notifier).track([peerId]);
      });
    }
    final presenceLine = peerPresence == null
        ? null
        : peerPresence.isOnline
        ? Strings.presenceOnline
        : formatLastSeen(peerPresence.lastSeenAt);
    final subtitle = otherTyping
        ? null
        : groupId == null
        ? (presenceLine == null || presenceLine.isEmpty ? null : presenceLine)
        : _memberLine(members, me?.id);

    return PopScope(
      canPop: !_selecting && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_searching) {
          _exitSearch();
        } else {
          _clearSelection();
        }
      },
      child: Scaffold(
        appBar: _selecting
            ? _selectionBar()
            : _searching
            ? _searchBar()
            : AppBar(
                titleSpacing: 0,
                actions: [
                  IconButton(
                    key: const ValueKey('thread-search'),
                    tooltip: Strings.chatSearch,
                    icon: const Icon(Icons.search),
                    onPressed: _enterSearch,
                  ),
                  PopupMenuButton<String>(
                    key: const ValueKey('thread-more'),
                    tooltip: Strings.chatMore,
                    onSelected: (v) {
                      if (v == 'scheduled') {
                        showScheduledMessagesSheet(context, widget.conversationId);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        key: ValueKey('thread-menu-scheduled'),
                        value: 'scheduled',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.schedule_send_rounded),
                          title: Text(Strings.scheduledTitle),
                        ),
                      ),
                    ],
                  ),
                ],
                title: display == null
                    ? const Text('Chat')
                    : InkWell(
                        onTap: () => context.push(
                          groupId == null
                              ? AppRoutes.chatDetails(widget.conversationId)
                              : AppRoutes.groupInfo(groupId),
                        ),
                        child: Row(
                          children: [
                            DoctorAvatar(
                              initials: display.initials,
                              size: AvatarSize.sm,
                              imageUrl: display.otherUser?.avatarPresignedUrl,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    display.title,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (subtitle != null)
                                    Text(
                                      subtitle,
                                      key: const ValueKey('thread-subtitle'),
                                      overflow: TextOverflow.ellipsis,
                                      style: subtitle == Strings.presenceOnline
                                          ? AppText.caption.copyWith(
                                              color: AppColors.presenceOnline,
                                              fontWeight: FontWeight.w600,
                                            )
                                          : AppText.caption,
                                    ),
                                  if (otherTyping)
                                    Text(
                                      'typing…',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.medBlue,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
        body: Column(
          children: [
            const ConnectivityBanner(),
            if (pinnedId != null)
              PinnedBanner(
                message: pinnedMsg,
                senderName: pinnedMsg == null ? null : _nameFor(pinnedMsg.senderId),
                nameFor: _nameFor,
                onTap: () => _jumpTo(pinnedId),
                onUnpin: canUnpin ? _unpin : null,
              ),
            Expanded(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e')),
                data: (allMsgs) {
                  if (!_initialJumpDone && allMsgs.isNotEmpty) {
                    _initialJumpDone = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      final target = widget.initialMessageId;
                      if (target != null) {
                        _jumpTo(target);
                      } else {
                        _resolveUnread(allMsgs, me?.id);
                      }
                    });
                  }
                  // Hide disappearing messages past their expiry even before the
                  // server purge tick; any rebuild re-filters.
                  final now = DateTime.now().toUtc();
                  final msgs = allMsgs
                      .where(
                        (m) => m.expiresAt == null || m.expiresAt!.isAfter(now),
                      )
                      .toList();
                  _trackNew(msgs, me?.id);
                  final notifier = ref.read(
                    messagesProvider(widget.conversationId).notifier,
                  );
                  // Batch 5 B/D: consecutive photos fold into album rows;
                  // the voice player learns how to find and fetch the next
                  // note in this thread.
                  final rows = groupIntoAlbums(msgs);
                  final indexOf = <String, int>{
                    for (var k = 0; k < msgs.length; k++) msgs[k].id: k,
                  };
                  final playback = ref.read(voicePlaybackProvider);
                  playback.resolverFor = _voiceSource;
                  playback.nextAfter = (endedId) {
                    final at = indexOf[endedId];
                    if (at == null) return null;
                    for (var k = at - 1; k >= 0; k--) {
                      final x = msgs[k];
                      if (x.type == MessageType.voiceNote && !x.isDeleted && x.status == MessageStatus.sent && x.conversationId == widget.conversationId) {
                        return x;
                      }
                    }
                    return null;
                  };
                  return Stack(
                    children: [
                      ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.sm,
                        ),
                        // +1 row at the top (list end) for the older-page spinner.
                        itemCount:
                            rows.length + (notifier.loadingOlder ? 1 : 0),
                        itemBuilder: (_, ri) {
                          if (ri >= rows.length) {
                            return const Padding(
                              padding: EdgeInsets.all(AppSpacing.md),
                              child: Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            );
                          }
                          final r = rows[ri];
                          final m = r.first;
                          // Grouping and day pills look at the message
                          // above, i.e. the one before the row's oldest.
                          final i = indexOf[r.last.id] ?? 0;
                          final isMine = me?.id == m.senderId;
                          Widget row = _selectable(
                            m,
                            r.isAlbum
                                ? _buildAlbum(r, isMine, msgs, i)
                                : _buildBubble(m, isMine, msgs, i),
                          );
                          // NEW messages only: sent slide from right, received
                          // from left. Keyed by id so history/pagination and
                          // recycled list elements never replay.
                          row = _MessageEntrance(
                            key: ValueKey('enter-${m.id}'),
                            animate: _entranceIds.contains(m.id),
                            fromRight: isMine,
                            onShown: () => _entranceIds.remove(m.id),
                            child: row,
                          );
                          // Day pill above the first message of each day
                          // (reversed list: "above" = index i + 1).
                          final showDay =
                              i == msgs.length - 1 ||
                              !_sameDay(
                                r.last.createdAt.toLocal(),
                                msgs[i + 1].createdAt.toLocal(),
                              );
                          if (showDay) {
                            row = Column(
                              children: [
                                _DateChip(
                                  label: _dayLabel(m.createdAt.toLocal()),
                                ),
                                row,
                              ],
                            );
                          }
                          return row;
                        },
                      ),
                      Positioned(
                        right: AppSpacing.lg,
                        bottom: AppSpacing.lg,
                        child: _JumpToBottomPill(
                          visible: _showJump,
                          unreadCount: _unseenCount,
                          onTap: _jumpToBottom,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (otherTyping) const TypingIndicator(),
            // Anyone who can open this thread can send: the server allows
            // direct chats only between colleagues or connections.
            postingClosed
                ? _postingClosedNotice()
                : Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _onComposerPointerDown,
                    onPointerMove: _onComposerPointerMove,
                    onPointerUp: _onComposerPointerUp,
                    onPointerCancel: _onComposerPointerUp,
                    child: _showRecorder
                        ? VoiceRecorderPanel(
                            key: _recorderKey,
                            conversationId: widget.conversationId,
                            held: _recorderHeld,
                            onSent: _closeRecorder,
                            onCancel: _closeRecorder,
                          )
                        : _composer(),
                  ),
          ],
        ),
      ),
    );
  }

  /// Read-only footer for a member of an admins-only group.
  Widget _postingClosedNotice() => Container(
        key: const ValueKey('posting-closed'),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: const InlineBanner(
              tone: BannerTone.info,
              icon: Icons.lock_outline_rounded,
              text: Strings.groupAdminsOnlyNotice,
            ),
          ),
        ),
      );

  /// The normal message composer. [hideAttachments] drops the attach/mic
  /// affordances (request tier allows exactly one text message, no media).
  Widget _composer({bool hideAttachments = false}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_mentionActive != null && _members.isNotEmpty)
              MentionAutocomplete(
                members: _members.values.toList(),
                query: _mentionActive!.query,
                meId: ref.read(authProvider).user?.id,
                onPick: _pickMention,
              ),
            if (_editing != null) _editingStrip(_editing!),
            if (_replyingTo != null && _editing == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                child: QuoteStrip(
                  key: const ValueKey('composer-reply'),
                  quote: _replyingTo,
                  senderName: _quoteSender(_replyingTo!),
                  isMine: false,
                  nameFor: _nameFor,
                  onClose: _cancelReply,
                ),
              ),
            if (_composerPreviewUrl != null && _editing == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
                child: LinkPreviewCard(
                  key: const ValueKey('composer-link-preview'),
                  url: _composerPreviewUrl!,
                  isMine: false,
                  onClose: () => setState(() {
                    _dismissedPreviewUrl = _composerPreviewUrl;
                    _composerPreviewUrl = null;
                  }),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: TextField(
                        key: const ValueKey('composer-input'),
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.send,
                        contextMenuBuilder: _composerContextMenu,
                        onTapOutside: (_) => FocusScope.of(context).unfocus(),
                        decoration: InputDecoration(
                          hintText: Strings.chatMessageHint,
                          border: OutlineInputBorder(
                            borderRadius: AppRadii.rXl,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md + 2,
                            vertical: AppSpacing.md - 2,
                          ),
                        ),
                        onChanged: _onInputChanged,
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  // WhatsApp-style morph: attach + mic when idle, send while
                  // typing — scale+fade swap, never a snap. In request mode the
                  // idle affordances collapse to nothing (text-only).
                  AnimatedSwitcher(
                    duration: AppMotion.maybe(context, AppMotion.micro),
                    switchInCurve: AppMotion.curveEnter,
                    switchOutCurve: AppMotion.curveExit,
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: _hasText
                        ? AppPressable(
                            key: const ValueKey('composer-send'),
                            haptic: true,
                            minTarget: true,
                            onTap: _send,
                            onLongPress: _openScheduleSheet,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: const BoxDecoration(
                                color: AppColors.medBlue,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _editing != null
                                    ? Icons.check_rounded
                                    : Icons.send_rounded,
                                color: AppColors.white,
                                size: 20,
                              ),
                            ),
                          )
                        : hideAttachments
                        ? const SizedBox(
                            key: ValueKey('composer-idle-empty'),
                            height: 44,
                          )
                        : Row(
                            key: const ValueKey('composer-idle'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                key: const ValueKey('composer-attach'),
                                onPressed: _pickAttachment,
                                icon: const Icon(
                                  Icons.attach_file,
                                  color: AppColors.medBlue,
                                ),
                              ),
                              // Tap → review panel; hold → record while
                              // held (pointer handled by the Listener above
                              // the composer, see _onComposerPointerDown).
                              Semantics(
                                button: true,
                                label: 'Record voice note',
                                child: SizedBox(
                                  key: _micKey,
                                  width: 48,
                                  height: 48,
                                  child: const Icon(
                                    Icons.mic,
                                    key: ValueKey('composer-mic'),
                                    color: AppColors.medBlue,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "Editing message" strip above the composer with the original text and a
  /// close button that abandons the edit.
  Widget _editingStrip(Message m) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.xs,
        0,
      ),
      child: Row(
        children: [
          const Icon(Icons.edit_outlined, size: 18, color: AppColors.medBlue),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Strings.chatEditingMessage,
                  style: AppText.label.copyWith(color: AppColors.medBlue),
                ),
                Text(
                  m.content ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _cancelEdit,
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
    );
  }
}

/// One-shot entrance for a NEW message bubble: fade + horizontal slide
/// (sent from the right, received from the left). History renders instantly
/// (`animate: false`). Keyed by message id so list recycling never replays.
class _MessageEntrance extends StatefulWidget {
  final bool animate;
  final bool fromRight;
  final VoidCallback? onShown;
  final Widget child;

  const _MessageEntrance({
    super.key,
    required this.animate,
    required this.fromRight,
    this.onShown,
    required this.child,
  });

  @override
  State<_MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<_MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.enter,
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.curveEnter,
  );

  bool _started = false;

  @override
  void initState() {
    super.initState();
    if (!widget.animate) _controller.value = 1.0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.animate) return;
    widget.onShown?.call(); // one-shot: never replay after recycle
    if (AppMotion.reduced(context)) {
      _controller.value = 1.0;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isCompleted) return widget.child;
    final dx = widget.fromRight ? 24.0 : -24.0;
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: Offset(dx * (1 - _t.value), 0),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// Day-separator pill (Today / Yesterday / MMM d) between day groups.
class _DateChip extends StatelessWidget {
  final String label;
  const _DateChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: AppColors.gray100,
            borderRadius: AppRadii.rFull,
          ),
          child: Text(
            label,
            style: AppText.timestamp.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating scroll-to-bottom pill: fades + slides in when scrolled up past
/// the threshold; shows an unread badge for messages that arrived meanwhile.
class _JumpToBottomPill extends StatelessWidget {
  final bool visible;
  final int unreadCount;
  final VoidCallback onTap;

  const _JumpToBottomPill({
    required this.visible,
    required this.unreadCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.maybe(context, AppMotion.micro);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: duration,
        curve: visible ? AppMotion.curveEnter : AppMotion.curveExit,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 0.4),
          duration: duration,
          curve: visible ? AppMotion.curveEnter : AppMotion.curveExit,
          child: AppPressable(
            onTap: onTap,
            minTarget: true,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: AppRadii.rFull,
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.card,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (unreadCount > 0) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm - 2,
                        vertical: 2,
                      ),
                      decoration: const BoxDecoration(
                        color: AppColors.medBlue,
                        borderRadius: BorderRadius.all(
                          Radius.circular(AppRadii.full),
                        ),
                      ),
                      child: Text(
                        '$unreadCount',
                        style: AppText.badge.copyWith(
                          color: AppColors.onPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: AppColors.medBlue,
                    size: 22,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
