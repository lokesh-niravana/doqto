import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../core/utils/chat_list_filters.dart';
import '../data/api/api_client.dart';
import '../data/api/websocket_client.dart';
import '../data/models/conversation.dart';
import '../data/models/conversation_prefs.dart';
import '../data/models/message.dart';
import '../data/repositories/chat_repository.dart';
import '../data/services/chat_document_store.dart';
import '../data/services/chat_media_cache.dart';
import '../data/services/outbox.dart';
import 'auth_state.dart';
import 'realtime_state.dart';

/// Conversation list that live-updates: re-fetches in place (no loading flash)
/// whenever anything that the list shows changes — a message sent/received,
/// edited or deleted (preview), read state (unread badge), membership (a chat
/// appears or disappears), a group rename. Bursts coalesce into one fetch.
/// Cache-first so a cold start offline still shows the list.
class ConversationsNotifier extends AsyncNotifier<List<Conversation>> {
  static const _refreshOn = {
    WsEventServer.newMessage,
    WsEventServer.messageRead,
    WsEventServer.messageEdited,
    WsEventServer.messageDeleted,
    WsEventServer.memberAdded,
    WsEventServer.memberRemoved,
    WsEventServer.groupUpdated,
    WsEventServer.groupMemberJoined,
  };

  @override
  Future<List<Conversation>> build() async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        if (event.type == WsEventServer.conversationPrefsUpdated) {
          // My other device changed a pin / mute / …: patch in place, no fetch.
          final id = event.data['conversation_id'] as String?;
          final raw = event.data['prefs'];
          if (id != null && raw is Map) {
            _applyPrefs(id, ConversationPrefs.fromJson(raw.cast<String, dynamic>()));
          }
          return;
        }
        if (event.type == WsEventServer.messagePinned ||
            event.type == WsEventServer.messageUnpinned) {
          // Shared pin changed (someone pinned / unpinned / the pin lapsed):
          // patch the conversation in place so the banner follows at once.
          final id = event.data['conversation_id'] as String?;
          if (id != null) {
            final until = event.data['pinned_until'] as String?;
            _applyPin(
              id,
              event.type == WsEventServer.messagePinned
                  ? event.data['message_id'] as String?
                  : null,
              until == null ? null : DateTime.tryParse(until),
            );
          }
          return;
        }
        if (_refreshOn.contains(event.type)) refresh();
      },
    );

    final cache = ref.read(chatCacheProvider);
    final cached = cache.conversations();
    if (cached != null) state = AsyncData(cached); // instant paint offline
    try {
      final fresh = await ref.read(chatRepositoryProvider).listConversations();
      await cache.putConversations(fresh);
      _scheduleAutoUnarchive(fresh);
      return fresh;
    } catch (_) {
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<void> refresh() async {
    try {
      final list = await ref.read(chatRepositoryProvider).listConversations();
      await ref.read(chatCacheProvider).putConversations(list);
      state = AsyncData(
        list,
      ); // stays on previous data until this resolves → no flash
      _scheduleAutoUnarchive(list);
    } catch (_) {
      // Offline refresh: keep showing what we have.
    }
  }

  // ---- Conversation preferences (batch 3) ---------------------------------

  /// "Keep chats archived" off: an archived chat that received something new
  /// comes back to the list on its own. Bounded — once unarchived it no
  /// longer matches, and nothing here re-archives.
  void _scheduleAutoUnarchive(List<Conversation> list) {
    if (ref.read(keepArchivedProvider)) return;
    for (final c in list) {
      if (c.prefs.archived && c.unreadCount > 0) {
        unawaited(archive(c.id, false).catchError((_) {}));
      }
    }
  }

  Conversation? conversation(String id) {
    for (final c in state.value ?? const <Conversation>[]) {
      if (c.id == id) return c;
    }
    return null;
  }

  void _applyPrefs(String convId, ConversationPrefs prefs) {
    final current = state.value;
    if (current == null) return;
    final next = [
      for (final c in current) c.id == convId ? c.copyWith(prefs: prefs) : c,
    ];
    state = AsyncData(next);
    unawaited(ref.read(chatCacheProvider).putConversations(next));
  }

  void _applyPin(String convId, String? messageId, DateTime? until) {
    final current = state.value;
    if (current == null) return;
    final next = [
      for (final c in current)
        c.id == convId
            ? c.copyWith(pinnedMessageId: () => messageId, pinnedUntil: () => until)
            : c,
    ];
    state = AsyncData(next);
    unawaited(ref.read(chatCacheProvider).putConversations(next));
  }

  /// Pin a message for everyone (batch 4). Optimistic: the banner shows at
  /// once; the server's conversation replaces it, or the old pin comes back.
  Future<void> pinMessage(String convId, String messageId, int durationSec) async {
    final before = conversation(convId);
    _applyPin(
      convId,
      messageId,
      DateTime.now().toUtc().add(Duration(seconds: durationSec)),
    );
    try {
      final saved = await ref
          .read(chatRepositoryProvider)
          .pinMessage(convId, messageId, durationSec);
      _applyPin(convId, saved.pinnedMessageId, saved.pinnedUntil);
    } catch (_) {
      _applyPin(convId, before?.pinnedMessageId, before?.pinnedUntil);
      rethrow;
    }
  }

  Future<void> unpinMessage(String convId) async {
    final before = conversation(convId);
    _applyPin(convId, null, null);
    try {
      await ref.read(chatRepositoryProvider).unpinMessage(convId);
    } catch (_) {
      _applyPin(convId, before?.pinnedMessageId, before?.pinnedUntil);
      rethrow;
    }
  }

  void _remove(String convId) {
    final current = state.value;
    if (current == null) return;
    final next = [for (final c in current) if (c.id != convId) c];
    state = AsyncData(next);
    unawaited(ref.read(chatCacheProvider).putConversations(next));
  }

  /// Optimistic PATCH: show [optimistic] at once, replace it with the
  /// server's answer, or put the old prefs back and rethrow.
  Future<ConversationPrefs> setPrefs(
    String convId, {
    required ConversationPrefs optimistic,
    required Map<String, dynamic> patch,
  }) async {
    final before = conversation(convId)?.prefs ?? ConversationPrefs.defaults;
    _applyPrefs(convId, optimistic);
    try {
      final saved = await ref.read(chatRepositoryProvider).updatePrefs(convId, patch);
      _applyPrefs(convId, saved);
      return saved;
    } catch (_) {
      _applyPrefs(convId, before);
      rethrow;
    }
  }

  Future<void> pin(String convId, bool pinned) {
    final p = conversation(convId)?.prefs ?? ConversationPrefs.defaults;
    return setPrefs(
      convId,
      optimistic: p.copyWith(pinnedAt: () => pinned ? DateTime.now().toUtc() : null),
      patch: {'pinned': pinned},
    );
  }

  Future<void> archive(String convId, bool archived) {
    final p = conversation(convId)?.prefs ?? ConversationPrefs.defaults;
    return setPrefs(
      convId,
      optimistic: p.copyWith(archived: archived),
      patch: {'archived': archived},
    );
  }

  /// [until] null = unmute.
  Future<void> mute(String convId, DateTime? until) {
    final p = conversation(convId)?.prefs ?? ConversationPrefs.defaults;
    return setPrefs(
      convId,
      optimistic: p.copyWith(mutedUntil: () => until?.toUtc()),
      patch: {'muted_until': until?.toUtc().toIso8601String()},
    );
  }

  Future<void> markUnread(String convId, bool unread) {
    final p = conversation(convId)?.prefs ?? ConversationPrefs.defaults;
    return setPrefs(
      convId,
      optimistic: p.copyWith(markedUnread: unread),
      patch: {'marked_unread': unread},
    );
  }

  /// Hide everything so far from my view only; the thread reloads empty.
  Future<void> clearChat(String convId) async {
    final saved = await ref.read(chatRepositoryProvider).updatePrefs(convId, {'clear_chat': true});
    _applyPrefs(convId, saved);
    // The preview and unread badge are gone server-side; reflect it now
    // instead of waiting for the next list fetch.
    final current = state.value;
    if (current != null) {
      state = AsyncData([
        for (final x in current)
          if (x.id == convId)
            Conversation.fromJson({
              ...x.toJson(),
              'last_message_at': null,
              'last_message_preview': null,
              'last_message_sender_id': null,
              'last_message_type': null,
              'unread_count': 0,
            })
          else
            x,
      ]);
    }
    await ref.read(chatCacheProvider).putMessages(convId, const []);
    ref.invalidate(messagesProvider(convId));
  }

  /// Direct chat: clear + hide until something new arrives. Group: leave.
  Future<void> deleteChat(String convId) async {
    final c = conversation(convId);
    final meId = ref.read(authProvider).user?.id;
    if (c != null && c.type == ConversationType.group) {
      if (meId == null) return;
      await ref.read(chatRepositoryProvider).removeMember(convId, meId);
    } else {
      await ref.read(chatRepositoryProvider).updatePrefs(convId, {'delete_chat': true});
      await ref.read(chatCacheProvider).putMessages(convId, const []);
      ref.invalidate(messagesProvider(convId));
    }
    _remove(convId);
  }
}

/// Settings → "Keep chats archived" (batch 3). Default on. Off means a new
/// message brings an archived chat back to the list.
class KeepArchivedNotifier extends Notifier<bool> {
  @override
  bool build() {
    try {
      return ref.read(chatCacheProvider).keepArchived();
    } catch (_) {
      return true;
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      await ref.read(chatCacheProvider).setKeepArchived(value);
    } catch (_) {}
    if (!value && ref.exists(conversationsProvider)) {
      // Apply the new rule to what is already archived with unread.
      unawaited(ref.read(conversationsProvider.notifier).refresh());
    }
  }
}

final keepArchivedProvider =
    NotifierProvider<KeepArchivedNotifier, bool>(KeepArchivedNotifier.new);

/// Unsent composer text per conversation (batch 3). Backed by the encrypted
/// chat cache; the thread restores it on open, the list shows "Draft: …".
class DraftsNotifier extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    try {
      return ref.read(chatCacheProvider).drafts();
    } catch (_) {
      return const {};
    }
  }

  String? of(String convId) => state[convId];

  Future<void> set(String convId, String? text) async {
    final trimmed = text?.trim() ?? '';
    final has = state.containsKey(convId);
    if (trimmed.isEmpty) {
      if (has) state = {...state}..remove(convId);
    } else if (state[convId] != text) {
      state = {...state, convId: text!};
    }
    try {
      await ref.read(chatCacheProvider).putDraft(convId, trimmed.isEmpty ? null : text);
    } catch (_) {}
  }

  Future<void> clear(String convId) => set(convId, null);
}

final draftsProvider =
    NotifierProvider<DraftsNotifier, Map<String, String>>(DraftsNotifier.new);

/// Icon-badge number derived from the list (see [unreadTotalOf]).
final unreadTotalProvider = Provider<int>((ref) {
  final convs = ref.watch(conversationsProvider).asData?.value;
  return convs == null ? 0 : unreadTotalOf(convs);
});

/// Keeps the app-icon badge equal to [unreadTotalProvider]; clears it on
/// sign-out. Activated once by watching it from the root widget.
final appBadgeSyncProvider = Provider<void>((ref) {
  final badge = ref.watch(appBadgeProvider);
  ref.listen<int>(unreadTotalProvider, (_, total) {
    if (ref.read(authProvider).user != null) unawaited(badge.set(total));
  }, fireImmediately: true);
  ref.listen<AuthState>(authProvider, (_, next) {
    if (next.stage == AuthStage.signedOut) unawaited(badge.clear());
  });
});

final conversationsProvider =
    AsyncNotifierProvider<ConversationsNotifier, List<Conversation>>(
      ConversationsNotifier.new,
    );

/// Send an outbox entry over the wire per its kind. Shared by the per-thread
/// notifier and the global drainer; the server dedups by client_id, so
/// overlapping calls are harmless.
Future<Message> deliverOutboxEntry(ChatRepository repo, OutboxEntry e) async {
  switch (e.kind) {
    case OutboxKind.text:
      return repo.sendText(
        e.conversationId,
        e.content,
        clientId: e.clientId,
        replyToId: e.replyToId,
      );
    case OutboxKind.media:
      final bytes = await File(e.filePath!).readAsBytes();
      return repo.uploadFile(
        conversationId: e.conversationId,
        bytes: bytes,
        filename: e.fileName ?? e.filePath!.split('/').last,
        contentType: e.mimeType,
        clientId: e.clientId,
      );
    case OutboxKind.voice:
      final bytes = await File(e.filePath!).readAsBytes();
      return repo.uploadVoiceNote(
        conversationId: e.conversationId,
        bytes: bytes,
        filename: e.fileName ?? e.filePath!.split('/').last,
        durationSec: e.durationSec ?? 0,
        transcript: e.transcript,
        clientId: e.clientId,
      );
  }
}

/// The sender's own photo is already on disk: file it under the server id
/// before the outbox copy is deleted, so the sent bubble never downloads it.
Future<void> seedSentImage(
  ChatMediaCache cache,
  OutboxEntry e,
  Message msg,
) async {
  if (msg.type != MessageType.image || e.filePath == null) return;
  await cache.seed(msg.id, File(e.filePath!));
}

/// Same for a sent document: its own bubble opens without a download.
Future<void> seedSentDocument(
  ChatDocumentStore store,
  OutboxEntry e,
  Message msg,
) async {
  if (msg.type != MessageType.file || e.filePath == null) return;
  await store.seed(
    msg.id,
    msg.fileName ?? e.fileName ?? 'document',
    File(e.filePath!),
  );
}

/// True when the entry's media payload is gone from disk (nothing left to
/// send). Text entries always have their payload.
bool outboxEntryFileMissing(OutboxEntry e) =>
    e.kind != OutboxKind.text &&
    (e.filePath == null || !File(e.filePath!).existsSync());

class MessagesNotifier extends FamilyAsyncNotifier<List<Message>, String> {
  /// Older-page cursor state (read by the thread screen for the spinner row).
  bool hasMore = true;
  bool loadingOlder = false;

  /// Single-flight guard for forward catch-up.
  bool _catchingUp = false;
  static const _maxCatchUpPages = 10;

  /// Reactions: at most one request in flight per message; taps made while
  /// one is running collapse into the latest wanted state ([_ReactWant]).
  final _reactInFlight = <String>{};
  final _reactWanted = <String, _ReactWant>{};

  /// Stars: one request in flight per message, latest wanted state wins.
  final _starInFlight = <String>{};
  final _starWanted = <String, bool>{};
  static const _maxJumpPages = 40;

  @override
  Future<List<Message>> build(String conversationId) async {
    _listenWs(conversationId);

    final cache = ref.read(chatCacheProvider);
    final pending = _pendingAsMessages(conversationId);
    final cached = cache.messages(conversationId);
    if (cached != null) state = AsyncData([...pending, ...cached]);

    try {
      final msgs = await ref
          .read(chatRepositoryProvider)
          .listMessages(conversationId);
      hasMore = msgs.length >= AppConstants.messagesPageSize;
      await cache.putMessages(conversationId, msgs);
      return [...pending, ...msgs];
    } catch (_) {
      if (cached != null) return [...pending, ...cached];
      rethrow;
    }
  }

  /// Unsent outbox entries for this conversation, shown as clock-tick bubbles
  /// (they survive app restarts).
  List<Message> _pendingAsMessages(String conversationId) {
    final me = ref.read(authProvider).user?.id;
    if (me == null) return const [];
    final entries = ref
        .read(outboxProvider)
        .pending(conversationId: conversationId)
        .reversed; // newest first, matching list order
    return [
      for (final e in entries)
        Message.pending(
          clientId: e.clientId,
          conversationId: e.conversationId,
          senderId: me,
          content: e.content,
          type: switch (e.kind) {
            OutboxKind.text => MessageType.text,
            OutboxKind.media =>
              (e.mimeType ?? '').startsWith('image/')
                  ? MessageType.image
                  : MessageType.file,
            OutboxKind.voice => MessageType.voiceNote,
          },
          fileName: e.fileName,
          voiceDurationSec: e.durationSec,
          transcript: e.transcript,
          localPath: e.filePath,
          replyTo: e.replyToId == null ? null : _replyPreviewFor(e.replyToId!),
        ),
    ];
  }

  /// A quote strip for an unsent reply, from the cached target if we have it.
  ReplyPreview? _replyPreviewFor(String id) {
    final target = ref.read(chatCacheProvider).messages(arg)?.where((m) => m.id == id).firstOrNull;
    return target == null ? null : ReplyPreview.of(target);
  }

  void _listenWs(String conversationId) {
    final ws = ref.read(websocketClientProvider);
    final sub = ws.events.listen((event) {
      switch (event.type) {
        case WsEventServer.newMessage:
          final msg = Message.fromJson(event.data);
          if (msg.conversationId == conversationId) {
            final lastSeq = _maxSeq();
            _insert(msg);
            // Live gap detection: a seq jump means we missed broadcasts →
            // backfill. Holes in seq are legal (rollbacks), so an empty
            // catch-up result is fine.
            if (msg.seq != null && lastSeq != null && msg.seq! > lastSeq + 1) {
              _catchUp(conversationId);
            }
          }
          break;
        case WsEventServer.messageDelivered:
          // Conversation-level ack: flip gray double-checks on own messages.
          // The ack names who received (user_id): it covers only messages
          // someone ELSE sent. The server echoes it to the acker too, and
          // without this check their own unsent-to-anyone bubbles went gray.
          if (event.data['conversation_id'] != conversationId) break;
          final deliveredBy = event.data['user_id'] as String?;
          state = AsyncData([
            for (final m in state.value ?? <Message>[])
              if (m.senderId != deliveredBy) m.copyWith(delivered: true) else m,
          ]);
          break;
        case WsEventServer.messageRead:
          final convId = event.data['conversation_id'] as String?;
          final msgId = event.data['message_id'] as String?;
          // user_id is the READER. Reading a chat reads the other side's
          // messages, never your own: the server echoes this event to the
          // reader (so their list badge clears), and flipping every bubble
          // turned the reader's own sent messages blue.
          final readBy = event.data['user_id'] as String?;
          // Conversation-level read targets a specific conversation; per-message
          // read is matched by id below regardless of conversation.
          if (msgId == null && convId != conversationId) break;
          final current = state.value ?? [];
          state = AsyncData([
            for (final m in current)
              if ((msgId == null || m.id == msgId) && m.senderId != readBy)
                m.copyWith(read: true)
              else
                m,
          ]);
          break;
        case WsEventServer.messageEdited:
        case WsEventServer.messageDeleted:
          final msg = Message.fromJson(event.data);
          if (msg.conversationId == conversationId) _replace(msg);
          // A deleted photo must not linger on this phone.
          if (msg.isDeleted) {
            ref.read(chatMediaCacheProvider).evict(msg.id);
            ref.read(chatDocumentStoreProvider).evict(msg.id);
          }
          break;
        case WsEventServer.messageReacted:
          if (event.data['conversation_id'] != conversationId) break;
          _onReacted(event.data);
          break;
        case WsEventServer.messageStarred:
          // My other device starred / unstarred (private: only my devices
          // get this). While my own request runs, my echo is ignored.
          if (event.data['conversation_id'] != conversationId) break;
          final id = event.data['message_id'] as String?;
          final starred = event.data['starred'] as bool?;
          if (id == null || starred == null || _starInFlight.contains(id)) break;
          _patchStarred(id, starred);
          break;
        case WsEventServer.transcriptReady:
          final id = event.data['message_id'] as String;
          final transcript = event.data['transcript'] as String?;
          final current = state.value ?? [];
          state = AsyncData([
            for (final m in current)
              if (m.id == id)
                m.copyWith(
                  transcript: transcript,
                  transcriptStatus: TranscriptStatus.completed,
                )
              else
                m,
          ]);
          break;
        default:
          break;
      }
    });
    // Gap recovery: forward catch-up from the highest known seq on reconnect.
    final stateSub = ws.states.listen((s) {
      if (s == WsConnState.connected) _catchUp(conversationId);
    });
    ref.onDispose(sub.cancel);
    ref.onDispose(stateSub.cancel);
  }

  /// Highest server-assigned seq across loaded/cached messages — the forward
  /// sync cursor. Null when nothing loaded has a seq (legacy cache/first run).
  int? _maxSeq() {
    int? best;
    for (final m in state.value ?? const <Message>[]) {
      final s = m.seq;
      if (s != null && (best == null || s > best)) best = s;
    }
    return best;
  }

  /// Forward catch-up: pull everything after our highest seq in ascending
  /// pages until a short page. Covers arbitrarily large offline backlogs
  /// (the old page-1 refetch silently lost anything past 50 messages).
  /// Capped at [_maxCatchUpPages]; past that, fall back to a page-1 resync.
  Future<void> _catchUp(String conversationId) async {
    if (_catchingUp) return;
    _catchingUp = true;
    try {
      var after = _maxSeq();
      if (after == null) {
        await _refetchLatest(conversationId);
        return;
      }
      for (var page = 0; page < _maxCatchUpPages; page++) {
        final batch = await ref
            .read(chatRepositoryProvider)
            .listMessages(conversationId, afterSeq: after);
        for (final m in batch) {
          _insert(m); // existing id/clientId dedup applies
          final s = m.seq;
          if (s != null && s > after!) after = s;
        }
        if (batch.length < AppConstants.messagesPageSize) {
          await _catchUpChanges(conversationId);
          await _recache(conversationId);
          return;
        }
      }
      // Cap hit — backlog absurdly large; resync the latest page instead.
      await _refetchLatest(conversationId);
    } catch (_) {
      // Offline again — the next reconnect retries.
    } finally {
      _catchingUp = false;
    }
  }

  /// Post-send changes (edits, deletes, reactions) to rows we already hold,
  /// made while we were offline. seq catch-up only finds NEW messages.
  /// Cursor: the newest changedAt we know of, else the oldest loaded row's
  /// createdAt (any later change to a loaded row is newer than that).
  Future<void> _catchUpChanges(String conversationId) async {
    final loaded = (state.value ?? const <Message>[])
        .where((m) => m.status == MessageStatus.sent && m.seq != null)
        .toList();
    if (loaded.isEmpty) return;
    DateTime? cursor;
    for (final m in loaded) {
      final c = m.changedAt;
      if (c != null && (cursor == null || c.isAfter(cursor))) cursor = c;
    }
    cursor ??= loaded
        .map((m) => m.createdAt)
        .reduce((a, b) => a.isBefore(b) ? a : b)
        .subtract(const Duration(seconds: 1));
    for (var page = 0; page < _maxCatchUpPages; page++) {
      final batch = await ref
          .read(chatRepositoryProvider)
          .listMessages(conversationId, changedSince: cursor);
      final byId = {for (final m in batch) m.id: m};
      final current = state.value ?? const <Message>[];
      state = AsyncData([
        for (final m in current)
          if (byId[m.id] case final fresh? when _isNewer(fresh.changedAt, m.changedAt))
            fresh.copyWith(
              read: m.read || fresh.read,
              delivered: m.delivered || fresh.delivered,
              starred: m.starred || fresh.starred,
            )
          else
            m,
      ]);
      for (final m in batch) {
        if (byId.containsKey(m.id) && m.isDeleted) {
          await ref.read(chatMediaCacheProvider).evict(m.id);
          await ref.read(chatDocumentStoreProvider).evict(m.id);
        }
      }
      final last = batch.lastOrNull?.changedAt;
      if (batch.length < AppConstants.messagesPageSize || last == null) return;
      cursor = last;
    }
  }

  static bool _isNewer(DateTime? incoming, DateTime? current) =>
      incoming != null && (current == null || incoming.isAfter(current));

  /// Write the newest page-worth of delivered messages back to the cache.
  Future<void> _recache(String conversationId) async {
    final sent = (state.value ?? const <Message>[])
        .where((m) => m.status == MessageStatus.sent)
        .take(AppConstants.messagesPageSize)
        .toList();
    if (sent.isEmpty) return;
    await ref.read(chatCacheProvider).putMessages(conversationId, sent);
  }

  /// Fallback resync: refetch page 1 and merge (dedup by id).
  Future<void> _refetchLatest(String conversationId) async {
    try {
      final fresh = await ref
          .read(chatRepositoryProvider)
          .listMessages(conversationId);
      final current = state.value ?? [];
      final freshIds = {for (final m in fresh) m.id};
      // Keep what the page doesn't cover: pending/failed bubbles and older pages.
      final keep = current.where((m) => !freshIds.contains(m.id));
      final merged = [...keep, ...fresh]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      state = AsyncData(merged);
      await ref.read(chatCacheProvider).putMessages(conversationId, fresh);
    } catch (_) {}
  }

  /// [replyTo] quotes a message of this conversation (batch 4).
  Future<void> sendText(String text, {ReplyPreview? replyTo}) async {
    final content = text.trim();
    if (content.isEmpty) return;
    final me = ref.read(authProvider).user?.id;
    if (me == null) return;

    // 1. Durably queue + optimistic bubble BEFORE any network I/O — a dead
    //    network can no longer lose the message.
    final entry = OutboxEntry(
      clientId: uuidV4(),
      conversationId: arg,
      content: content,
      createdAt: DateTime.now().toUtc(),
      replyToId: replyTo?.id,
    );
    await ref.read(outboxProvider).add(entry);
    _insert(
      Message.pending(
        clientId: entry.clientId,
        conversationId: arg,
        senderId: me,
        content: content,
        replyTo: replyTo,
      ),
    );

    // 2. Attempt delivery.
    await _deliver(entry);
  }

  /// Send one outbox entry (any kind); replace the pending bubble on success,
  /// mark it failed on error. Safe to call twice — the server dedups by
  /// client_id.
  Future<void> _deliver(OutboxEntry entry) async {
    // Media whose durable copy vanished can never be sent — drop the entry
    // and leave a failed bubble (discard removes it).
    if (outboxEntryFileMissing(entry)) {
      await ref.read(outboxProvider).remove(entry.clientId);
      _setStatus(entry.clientId, MessageStatus.failed);
      return;
    }
    try {
      final msg = await deliverOutboxEntry(
        ref.read(chatRepositoryProvider),
        entry,
      );
      await seedSentImage(ref.read(chatMediaCacheProvider), entry, msg);
      await seedSentDocument(ref.read(chatDocumentStoreProvider), entry, msg);
      await ref.read(outboxProvider).remove(entry.clientId);
      _insert(msg);
    } catch (_) {
      _setStatus(entry.clientId, MessageStatus.failed);
    }
  }

  /// Tap-to-retry on a failed bubble.
  Future<void> retry(String clientId) async {
    final entry = ref
        .read(outboxProvider)
        .pending(conversationId: arg)
        .where((e) => e.clientId == clientId)
        .firstOrNull;
    if (entry == null) return;
    _setStatus(clientId, MessageStatus.sending);
    await _deliver(entry);
  }

  /// Discard a failed message entirely.
  Future<void> discard(String clientId) async {
    await ref.read(outboxProvider).remove(clientId);
    final current = state.value ?? [];
    state = AsyncData([...current.where((m) => m.clientId != clientId)]);
  }

  void _setStatus(String clientId, MessageStatus status) {
    final current = state.value ?? [];
    state = AsyncData([
      for (final m in current)
        if (m.clientId == clientId) m.copyWith(status: status) else m,
    ]);
  }

  /// Outbox-first media send: persist the payload to app storage, enqueue,
  /// show the optimistic bubble, then deliver in the background — a dead
  /// network can no longer lose the attachment.
  Future<void> sendUpload({
    required List<int> bytes,
    required String filename,
    String? contentType,
  }) async {
    final me = ref.read(authProvider).user?.id;
    if (me == null) return;
    final clientId = uuidV4();
    final path = await ref
        .read(outboxMediaStoreProvider)
        .persistBytes(clientId: clientId, fileName: filename, bytes: bytes);
    final entry = OutboxEntry(
      clientId: clientId,
      conversationId: arg,
      kind: OutboxKind.media,
      createdAt: DateTime.now().toUtc(),
      filePath: path,
      fileName: filename,
      mimeType: contentType,
    );
    await ref.read(outboxProvider).add(entry);
    _insert(
      Message.pending(
        clientId: clientId,
        conversationId: arg,
        senderId: me,
        type: (contentType ?? '').startsWith('image/')
            ? MessageType.image
            : MessageType.file,
        fileName: filename,
        localPath: path,
      ),
    );
    unawaited(_deliver(entry));
  }

  /// Outbox-first voice-note send. Copies the recording out of the OS temp
  /// dir first, so the panel can dismiss (and the temp file die) immediately.
  Future<void> sendVoice({
    required String sourcePath,
    required int durationSec,
    String? transcript,
  }) async {
    final me = ref.read(authProvider).user?.id;
    if (me == null) return;
    final clientId = uuidV4();
    final path = await ref
        .read(outboxMediaStoreProvider)
        .persistFile(clientId: clientId, sourcePath: sourcePath);
    final entry = OutboxEntry(
      clientId: clientId,
      conversationId: arg,
      kind: OutboxKind.voice,
      createdAt: DateTime.now().toUtc(),
      filePath: path,
      fileName: sourcePath.split('/').last,
      durationSec: durationSec,
      transcript: transcript,
    );
    await ref.read(outboxProvider).add(entry);
    _insert(
      Message.pending(
        clientId: clientId,
        conversationId: arg,
        senderId: me,
        type: MessageType.voiceNote,
        voiceDurationSec: durationSec,
        transcript: transcript,
      ),
    );
    unawaited(_deliver(entry));
  }

  /// Load the next older page (cursor = oldest fetched message).
  Future<void> loadOlder() async {
    if (!hasMore || loadingOlder) return;
    final current = state.value ?? [];
    final oldest = current
        .where((m) => m.status == MessageStatus.sent)
        .lastOrNull;
    if (oldest == null) return;
    loadingOlder = true;
    try {
      final older = await ref
          .read(chatRepositoryProvider)
          .listMessages(arg, before: oldest.createdAt);
      hasMore = older.length >= AppConstants.messagesPageSize;
      final ids = {for (final m in current) m.id};
      state = AsyncData([
        ...current,
        ...older.where((m) => !ids.contains(m.id)),
      ]);
    } catch (_) {
      // Scroll again to retry.
    } finally {
      loadingOlder = false;
      // Nudge listeners so the spinner row rebuilds even on failure.
      state = AsyncData([...(state.value ?? [])]);
    }
  }

  Message? messageById(String id) =>
      (state.value ?? const <Message>[]).where((m) => m.id == id).firstOrNull;

  /// Pull older pages until [messageId] is loaded (tap on a quote, the pin
  /// banner, a starred row). False when history ran out without it.
  Future<bool> ensureLoaded(String messageId) async {
    for (var page = 0; page < _maxJumpPages; page++) {
      if (messageById(messageId) != null) return true;
      if (!hasMore) return false;
      final before = (state.value ?? const <Message>[]).length;
      await loadOlder();
      if ((state.value ?? const <Message>[]).length == before && !hasMore) return false;
    }
    return messageById(messageId) != null;
  }

  /// Keep pulling older pages while [more] says so (in-chat search: until a
  /// hit appears or history runs out). Returns false when exhausted.
  Future<bool> loadOlderWhile(bool Function(List<Message> loaded) more) async {
    for (var page = 0; page < _maxJumpPages; page++) {
      final loaded = state.value ?? const <Message>[];
      if (!more(loaded)) return true;
      if (!hasMore) return false;
      await loadOlder();
    }
    return false;
  }

  /// Jump to a calendar day (batch 4): the newest message on or before the
  /// end of [day] (UTC), fetched with `before_date`, then the gap between it
  /// and what is loaded is filled so the thread stays continuous. Returns
  /// that message's id, or null when nothing is that old.
  Future<String?> jumpToDate(DateTime day) async {
    final endOfDay = DateTime.utc(day.year, day.month, day.day, 23, 59, 59, 999);
    final loaded = state.value ?? const <Message>[];
    Message? newestOnOrBefore(List<Message> list) {
      Message? best;
      for (final m in list) {
        if (m.status != MessageStatus.sent || m.createdAt.isAfter(endOfDay)) continue;
        if (best == null || m.createdAt.isAfter(best.createdAt)) best = m;
      }
      return best;
    }
    final oldest = loaded.where((m) => m.status == MessageStatus.sent).lastOrNull;
    if (oldest != null && !oldest.createdAt.isAfter(endOfDay)) {
      return newestOnOrBefore(loaded)?.id;
    }
    if (loadingOlder) return null;
    loadingOlder = true;
    try {
      final repo = ref.read(chatRepositoryProvider);
      final page = await repo.listMessages(arg, beforeDate: day);
      if (page.isEmpty) return null;
      final target = page.first;
      // Fill the gap from what we hold down to the target page.
      var current = state.value ?? const <Message>[];
      var cursor = current.where((m) => m.status == MessageStatus.sent).lastOrNull?.createdAt;
      var merged = <Message>[...current];
      final ids = {for (final m in merged) m.id};
      for (var n = 0; n < _maxJumpPages && cursor != null && cursor.isAfter(target.createdAt); n++) {
        final gap = await repo.listMessages(arg, before: cursor);
        if (gap.isEmpty) break;
        for (final m in gap) {
          if (ids.add(m.id)) merged.add(m);
        }
        cursor = gap.last.createdAt;
        if (gap.length < AppConstants.messagesPageSize) break;
      }
      for (final m in page) {
        if (ids.add(m.id)) merged.add(m);
      }
      merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      hasMore = page.length >= AppConstants.messagesPageSize;
      state = AsyncData(merged);
      return target.id;
    } catch (_) {
      return null;
    } finally {
      loadingOlder = false;
      state = AsyncData([...(state.value ?? [])]);
    }
  }

  /// Star / unstar for me (batch 4). Optimistic with rollback, one request
  /// in flight per message like [react].
  Future<void> star(String messageId, bool starred) async {
    final msg = messageById(messageId);
    if (msg == null || !msg.canStar) return;
    if (msg.starred == starred && !_starInFlight.contains(messageId)) return;
    _patchStarred(messageId, starred);
    _starWanted[messageId] = starred;
    if (!_starInFlight.add(messageId)) return;
    final before = msg.starred;
    final repo = ref.read(chatRepositoryProvider);
    try {
      var confirmed = before;
      while (_starWanted.containsKey(messageId)) {
        final want = _starWanted.remove(messageId)!;
        confirmed = (await repo.setStarred(messageId, want)).starred;
      }
      _patchStarred(messageId, confirmed);
    } catch (_) {
      _starWanted.remove(messageId);
      _patchStarred(messageId, before);
      rethrow;
    } finally {
      _starInFlight.remove(messageId);
      _recache(arg);
    }
  }

  void _patchStarred(String messageId, bool starred) {
    state = AsyncData([
      for (final m in state.value ?? const <Message>[])
        if (m.id == messageId) m.copyWith(starred: starred) else m,
    ]);
  }

  /// Forward [messageIds] to [conversationIds] (≤5). Copies land in the
  /// destination threads over WS; nothing changes here.
  Future<void> forward(List<String> messageIds, List<String> conversationIds) async {
    final repo = ref.read(chatRepositoryProvider);
    for (final id in messageIds) {
      await repo.forward(id, conversationIds);
    }
  }

  /// Edit within 15 min of sending (server-enforced). Applies the returned row.
  Future<void> edit(String messageId, String content) async {
    _replace(
      await ref.read(chatRepositoryProvider).editMessage(messageId, content),
    );
  }

  /// Delete for everyone: sender within 48 h, group admin any time
  /// (server-enforced). Applies the tombstone.
  Future<void> delete(String messageId) async {
    _replace(await ref.read(chatRepositoryProvider).deleteMessage(messageId));
    await ref.read(chatMediaCacheProvider).evict(messageId);
    await ref.read(chatDocumentStoreProvider).evict(messageId);
  }

  /// React to a message ([emoji] null = remove mine). Optimistic: the pill
  /// changes at once; the server's answer confirms it, a failure restores
  /// the last server-confirmed reactions and rethrows (the screen shows a
  /// snackbar). Fast repeated taps send at most one request at a time.
  Future<void> react(String messageId, String? emoji) async {
    final me = ref.read(authProvider).user?.id;
    if (me == null) return;
    final msg = (state.value ?? const <Message>[])
        .where((m) => m.id == messageId)
        .firstOrNull;
    if (msg == null || !msg.canReact) return;
    if (msg.myReaction(me) == emoji && !_reactInFlight.contains(messageId)) return;

    _patchReactions(messageId, MessageReaction.apply(msg.reactions, me, emoji));
    _reactWanted[messageId] = _ReactWant(emoji);
    if (!_reactInFlight.add(messageId)) return; // the running loop sends it

    var confirmed = msg.reactions;
    DateTime? confirmedAt = msg.changedAt;
    final repo = ref.read(chatRepositoryProvider);
    try {
      while (_reactWanted.containsKey(messageId)) {
        final want = _reactWanted.remove(messageId)!;
        final out = want.emoji == null
            ? await repo.removeReaction(messageId)
            : await repo.setReaction(messageId, want.emoji!);
        confirmed = out.reactions;
        confirmedAt = out.changedAt ?? confirmedAt;
      }
      _patchReactions(messageId, confirmed, changedAt: confirmedAt, onlyIfNewer: true);
    } catch (_) {
      _reactWanted.remove(messageId);
      _patchReactions(messageId, confirmed, changedAt: confirmedAt);
      rethrow;
    } finally {
      _reactInFlight.remove(messageId);
      _recache(arg);
    }
  }

  /// WS `message_reacted`: patch reactions only (never the whole row, so
  /// ticks survive). Out-of-order events are dropped by changed_at. While my
  /// own request is in flight, my echo is ignored and someone else's change
  /// is applied with my pending choice laid back on top.
  void _onReacted(Map<String, dynamic> data) {
    final id = data['message_id'] as String?;
    final changedAt = data['changed_at'] != null
        ? DateTime.tryParse(data['changed_at'] as String)
        : null;
    if (id == null || changedAt == null) return;
    final me = ref.read(authProvider).user?.id;
    var reactions = MessageReaction.listFromJson(data['reactions']);
    if (_reactInFlight.contains(id) && me != null) {
      if (data['actor_id'] == me) return;
      final pending = _reactWanted[id];
      final mine = (state.value ?? const <Message>[])
          .where((m) => m.id == id)
          .firstOrNull
          ?.myReaction(me);
      reactions = MessageReaction.apply(
        reactions,
        me,
        pending != null ? pending.emoji : mine,
      );
    }
    _patchReactions(id, reactions, changedAt: changedAt, onlyIfNewer: true);
    _recache(arg);
  }

  void _patchReactions(
    String messageId,
    List<MessageReaction> reactions, {
    DateTime? changedAt,
    bool onlyIfNewer = false,
  }) {
    final current = state.value ?? const <Message>[];
    state = AsyncData([
      for (final m in current)
        if (m.id == messageId &&
            (!onlyIfNewer ||
                changedAt == null ||
                m.changedAt == null ||
                !changedAt.isBefore(m.changedAt!)))
          m.copyWith(reactions: reactions, changedAt: changedAt)
        else
          m,
    ]);
  }

  /// "Delete for me": drop the rows locally after the server hides them.
  Future<void> hide(List<String> messageIds) async {
    await ref.read(chatRepositoryProvider).hideMessages(messageIds);
    final media = ref.read(chatMediaCacheProvider);
    final documents = ref.read(chatDocumentStoreProvider);
    for (final id in messageIds) {
      await media.evict(id);
      await documents.evict(id);
    }
    final ids = messageIds.toSet();
    state = AsyncData([
      for (final m in state.value ?? [])
        if (!ids.contains(m.id)) m,
    ]);
    await _recache(arg);
  }

  /// Replace a server row in place (edit/delete), keeping local tick state
  /// and my star (fan-outs always carry `starred: false`).
  void _replace(Message msg) {
    final current = state.value ?? [];
    state = AsyncData([
      for (final m in current)
        if (m.id == msg.id)
          msg.copyWith(read: m.read, delivered: m.delivered, starred: m.starred || msg.starred)
        else
          m,
    ]);
    _recache(msg.conversationId);
  }

  void _insert(Message msg) {
    final current = state.value ?? [];
    // Replace the optimistic bubble once the server row exists (matched by
    // client_id — covers both the POST response and the WS broadcast).
    if (msg.clientId != null &&
        current.any((m) => m.clientId == msg.clientId)) {
      state = AsyncData([
        for (final m in current)
          if (m.clientId == msg.clientId) msg else m,
      ]);
      return;
    }
    // If WS already pushed it, don't duplicate.
    if (current.any((m) => m.id == msg.id)) return;
    state = AsyncData([msg, ...current]);
  }
}

class _ReactWant {
  final String? emoji;
  const _ReactWant(this.emoji);
}

final messagesProvider =
    AsyncNotifierProvider.family<MessagesNotifier, List<Message>, String>(
      MessagesNotifier.new,
    );

/// Drains the outbox whenever the socket (re)connects and once on app start.
/// Successful sends reach open threads via the WS broadcast (matched by
/// client_id); server-side idempotency makes overlapping retries harmless.
final outboxDrainerProvider = Provider<void>((ref) {
  final repo = ref.watch(chatRepositoryProvider);
  final outbox = ref.watch(outboxProvider);

  Future<void> drain() async {
    for (final e in outbox.pending()) {
      // Media payload evicted from disk — the entry can never succeed.
      if (outboxEntryFileMissing(e)) {
        await outbox.remove(e.clientId);
        continue;
      }
      try {
        final msg = await deliverOutboxEntry(repo, e);
        await seedSentImage(ref.read(chatMediaCacheProvider), e, msg);
        await seedSentDocument(ref.read(chatDocumentStoreProvider), e, msg);
        await outbox.remove(e.clientId);
      } on ApiException catch (err) {
        // 413: payload too large — permanent for THIS entry, but the network
        // is clearly up, so keep draining the rest. The thread screen's
        // retry/discard flow handles the stuck entry.
        if (err.status == 413) continue;
        return; // other API failure — stop; next reconnect retries
      } catch (_) {
        return; // still offline — stop; next reconnect retries
      }
    }
  }

  final sub = ref.watch(websocketClientProvider).states.listen((s) {
    if (s == WsConnState.connected) drain();
  });
  ref.onDispose(sub.cancel);
  drain(); // app start
});

/// True when the *other* participant is currently typing in this conversation.
/// Auto-clears after 5s in case a typing_stop event is dropped.
class TypingNotifier extends FamilyNotifier<bool, String> {
  Timer? _clear;

  @override
  bool build(String conversationId) {
    final ws = ref.read(websocketClientProvider);
    final sub = ws.events.listen((event) {
      if (event.type != WsEventServer.typingStart &&
          event.type != WsEventServer.typingStop) {
        return;
      }
      final convId = event.data['conversation_id'] as String?;
      final uid = event.data['user_id'] as String?;
      // Read `me` per event: a thread opened from a notification tap at cold
      // start builds before auth has loaded, and a snapshot taken then would
      // be null forever — letting our own typing echo show as "B is typing".
      final me = ref.read(authProvider).user?.id;
      if (convId != conversationId || uid == me) return;
      if (event.type == WsEventServer.typingStart) {
        state = true;
        _clear?.cancel();
        _clear = Timer(const Duration(seconds: 6), () => state = false);
      } else {
        _clear?.cancel();
        state = false;
      }
    });
    ref.onDispose(() {
      _clear?.cancel();
      sub.cancel();
    });
    return false;
  }
}

final typingProvider = NotifierProvider.family<TypingNotifier, bool, String>(
  TypingNotifier.new,
);
