import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/api/api_client.dart';
import '../data/api/websocket_client.dart';
import '../data/models/conversation.dart';
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
        if (_refreshOn.contains(event.type)) refresh();
      },
    );

    final cache = ref.read(chatCacheProvider);
    final cached = cache.conversations();
    if (cached != null) state = AsyncData(cached); // instant paint offline
    try {
      final fresh = await ref.read(chatRepositoryProvider).listConversations();
      await cache.putConversations(fresh);
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
    } catch (_) {
      // Offline refresh: keep showing what we have.
    }
  }
}

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
      return repo.sendText(e.conversationId, e.content, clientId: e.clientId);
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
        ),
    ];
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

  Future<void> sendText(String text) async {
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
    );
    await ref.read(outboxProvider).add(entry);
    _insert(
      Message.pending(
        clientId: entry.clientId,
        conversationId: arg,
        senderId: me,
        content: content,
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

  /// Edit within 5 min of sending (server-enforced). Applies the returned row.
  Future<void> edit(String messageId, String content) async {
    _replace(
      await ref.read(chatRepositoryProvider).editMessage(messageId, content),
    );
  }

  /// Delete within 3 min of sending (server-enforced). Applies the tombstone.
  Future<void> delete(String messageId) async {
    _replace(await ref.read(chatRepositoryProvider).deleteMessage(messageId));
    await ref.read(chatMediaCacheProvider).evict(messageId);
    await ref.read(chatDocumentStoreProvider).evict(messageId);
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

  /// Replace a server row in place (edit/delete), keeping local tick state.
  void _replace(Message msg) {
    final current = state.value ?? [];
    state = AsyncData([
      for (final m in current)
        if (m.id == msg.id)
          msg.copyWith(read: m.read, delivered: m.delivered)
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
