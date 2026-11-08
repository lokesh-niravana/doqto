import '../../core/enums/app_enums.dart';
import '../../data/models/message.dart';

/// One row of the thread list: a single message, or an album of consecutive
/// photos from the same sender (batch 5). Albums are a client-side grouping —
/// every photo is still its own message on the server.
class ThreadRow {
  final List<Message> messages;
  const ThreadRow(this.messages);

  Message get first => messages.first; // newest (the list is newest-first)
  Message get last => messages.last; // oldest
  bool get isAlbum => messages.length > 1;

  /// The row's identity for keys: the newest photo's id, which also carries
  /// the caption.
  String get id => first.id;
}

/// Consecutive sent photos (no reply quote, not deleted) from one sender
/// within [window] of each other collapse into an album. [messages] is
/// newest-first, as the thread holds it; the result keeps that order and, in
/// each album, keeps the photos newest-first too.
List<ThreadRow> groupIntoAlbums(
  List<Message> messages, {
  Duration window = const Duration(seconds: 60),
}) {
  final rows = <ThreadRow>[];
  var i = 0;
  while (i < messages.length) {
    final m = messages[i];
    if (!_albumable(m)) {
      rows.add(ThreadRow([m]));
      i++;
      continue;
    }
    final group = [m];
    var j = i + 1;
    while (j < messages.length) {
      final prev = group.last; // older end of the group so far
      final cand = messages[j];
      if (!_albumable(cand) ||
          cand.senderId != prev.senderId ||
          prev.createdAt.difference(cand.createdAt).abs() > window) {
        break;
      }
      group.add(cand);
      j++;
    }
    rows.add(ThreadRow(group));
    i = j;
  }
  return rows;
}

bool _albumable(Message m) =>
    m.type == MessageType.image &&
    !m.isDeleted &&
    m.replyTo == null &&
    m.replyToId == null &&
    !m.forwarded;
