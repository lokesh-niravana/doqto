import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/models/media.dart';
import 'realtime_state.dart';

typedef GalleryKey = ({String conversationId, MediaKind kind});

/// One tab of a chat's gallery (batch 5): pages of
/// `GET /conversations/{id}/media?type=`, newest first, refetched when a
/// message in the chat changes.
class MediaGalleryNotifier extends FamilyAsyncNotifier<List<MediaGalleryItem>, GalleryKey> {
  String? _cursor;
  bool _loadingMore = false;

  bool get hasMore => _cursor != null;

  @override
  Future<List<MediaGalleryItem>> build(GalleryKey key) async {
    listenRealtime(
      ref,
      refresh: _refresh,
      onEvent: (event, refresh) {
        if (event.data['conversation_id'] != key.conversationId) return;
        if (event.type == WsEventServer.newMessage ||
            event.type == WsEventServer.messageDeleted ||
            event.type == WsEventServer.messageEdited) {
          refresh();
        }
      },
    );
    final page = await ref.read(chatRepositoryProvider).listMedia(key.conversationId, key.kind);
    _cursor = page.nextCursor;
    return page.data;
  }

  Future<void> _refresh() async {
    try {
      final page = await ref.read(chatRepositoryProvider).listMedia(arg.conversationId, arg.kind);
      _cursor = page.nextCursor;
      state = AsyncData(page.data);
    } catch (_) {}
  }

  Future<void> loadMore() async {
    final cursor = _cursor;
    if (cursor == null || _loadingMore) return;
    _loadingMore = true;
    try {
      final page = await ref
          .read(chatRepositoryProvider)
          .listMedia(arg.conversationId, arg.kind, cursor: cursor);
      _cursor = page.nextCursor;
      final current = state.value ?? const <MediaGalleryItem>[];
      final ids = {for (final i in current) i.message.id};
      state = AsyncData([
        ...current,
        ...page.data.where((i) => !ids.contains(i.message.id)),
      ]);
    } catch (_) {
    } finally {
      _loadingMore = false;
    }
  }

  /// Drop rows locally (delete for me).
  void remove(Set<String> messageIds) {
    state = AsyncData([
      for (final i in state.value ?? const <MediaGalleryItem>[])
        if (!messageIds.contains(i.message.id)) i,
    ]);
  }

  void patchStarred(Set<String> messageIds, bool starred) {
    state = AsyncData([
      for (final i in state.value ?? const <MediaGalleryItem>[])
        if (messageIds.contains(i.message.id))
          MediaGalleryItem(message: i.message.copyWith(starred: starred), urls: i.urls)
        else
          i,
    ]);
  }
}

final mediaGalleryProvider =
    AsyncNotifierProvider.family<MediaGalleryNotifier, List<MediaGalleryItem>, GalleryKey>(
  MediaGalleryNotifier.new,
);
