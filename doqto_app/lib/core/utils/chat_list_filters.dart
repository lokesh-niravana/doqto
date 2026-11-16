import '../../data/models/conversation.dart';
import '../enums/app_enums.dart';

/// Chip row under the chat-list search bar (batch 3).
enum ChatFilter {
  all('All'),
  unread('Unread'),
  groups('Groups'),
  archived('Archived');

  final String label;
  const ChatFilter(this.label);
}

/// Pinned chats first (in the order they were pinned), then everything else
/// by most recent activity.
List<Conversation> sortConversations(Iterable<Conversation> convs) {
  final list = [...convs];
  list.sort((a, b) {
    final pa = a.prefs.pinnedAt;
    final pb = b.prefs.pinnedAt;
    if (pa != null && pb != null) return pa.compareTo(pb);
    if (pa != null) return -1;
    if (pb != null) return 1;
    final ta = a.lastMessageAt ?? a.updatedAt;
    final tb = b.lastMessageAt ?? b.updatedAt;
    return tb.compareTo(ta);
  });
  return list;
}

/// True when the row should read as unread: real unread messages or the
/// hand-set dot.
bool isConversationUnread(Conversation c) =>
    c.unreadCount > 0 || c.prefs.markedUnread;

/// Rows for one filter. Archived chats only appear under [ChatFilter.archived].
List<Conversation> applyChatFilter(Iterable<Conversation> convs, ChatFilter filter) {
  return switch (filter) {
    ChatFilter.all => [for (final c in convs) if (!c.prefs.archived) c],
    ChatFilter.unread => [
        for (final c in convs)
          if (!c.prefs.archived && isConversationUnread(c)) c,
      ],
    ChatFilter.groups => [
        for (final c in convs)
          if (!c.prefs.archived && c.type == ConversationType.group) c,
      ],
    ChatFilter.archived => [for (final c in convs) if (c.prefs.archived) c],
  };
}

/// Icon-badge number: unread across the list minus muted and archived chats,
/// plus one for each chat marked unread by hand. Mirrors
/// `MessageService.unread_total` on the server.
int unreadTotalOf(Iterable<Conversation> convs, [DateTime? now]) {
  var total = 0;
  for (final c in convs) {
    if (c.prefs.archived || c.prefs.isMuted(now)) continue;
    total += c.unreadCount;
    if (c.unreadCount == 0 && c.prefs.markedUnread) total += 1;
  }
  return total;
}
