import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/message_edit.dart';

Message _msg({DateTime? createdAt, String? editedAt, String? deletedAt}) =>
    Message.fromJson({
      'id': 'm1',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'type': 'text',
      'content': 'hi',
      'transcript_status': 'none',
      'created_at': (createdAt ?? DateTime.utc(2026, 9, 5, 10)).toIso8601String(),
      'edited_at': editedAt,
      'deleted_at': deletedAt,
      'seq': 1,
    });

void main() {
  test('edited_at / deleted_at round-trip through json and copyWith', () {
    final m = _msg(editedAt: '2026-09-05T10:01:00Z');
    expect(m.editedAt, DateTime.utc(2026, 9, 5, 10, 1));
    expect(m.deletedAt, isNull);
    expect(m.isDeleted, isFalse);
    final back = Message.fromJson(m.toJson());
    expect(back.editedAt, m.editedAt);
    expect(back.copyWith(read: true).editedAt, m.editedAt);

    final d = _msg(deletedAt: '2026-09-05T10:02:00Z');
    expect(d.isDeleted, isTrue);
  });

  test('edit window is 15 min, delete window is 48 h, own text only; admins any age', () {
    final t0 = DateTime.utc(2026, 9, 5, 10);
    final m = _msg(createdAt: t0);
    expect(m.canEdit(me: 'u1', now: t0.add(const Duration(minutes: 14, seconds: 59))), isTrue);
    expect(m.canEdit(me: 'u1', now: t0.add(const Duration(minutes: 15, seconds: 1))), isFalse);
    expect(m.canEdit(me: 'u2', now: t0), isFalse);
    expect(m.canDelete(me: 'u1', now: t0.add(const Duration(hours: 47, minutes: 59))), isTrue);
    expect(m.canDelete(me: 'u1', now: t0.add(const Duration(hours: 48, seconds: 1))), isFalse);
    // A group admin deletes anyone's message at any age; a plain member can't.
    expect(m.canDelete(me: 'u2', now: t0.add(const Duration(days: 30)), isAdmin: true), isTrue);
    expect(m.canDelete(me: 'u2', now: t0, isAdmin: false), isFalse);

    final deleted = _msg(createdAt: t0, deletedAt: t0.toIso8601String());
    expect(deleted.canEdit(me: 'u1', now: t0), isFalse);
    expect(deleted.canDelete(me: 'u1', now: t0), isFalse);
  });

  test('WS event wire names and MessageEdit parse', () {
    expect(WsEventServer.fromWire('message_edited'), WsEventServer.messageEdited);
    expect(WsEventServer.fromWire('message_deleted'), WsEventServer.messageDeleted);
    expect(WsEventServer.messageEdited.wire, 'message_edited');
    final e = MessageEdit.fromJson({'content': 'old', 'replaced_at': '2026-09-05T10:01:00Z'});
    expect(e.content, 'old');
    expect(e.replacedAt, DateTime.utc(2026, 9, 5, 10, 1));
  });
}
