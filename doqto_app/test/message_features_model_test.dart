import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/services/outbox.dart';

/// Batch 4 wire fields on Message / Conversation / Organization, and the
/// client-side rules built on them.
Message _msg(Map<String, dynamic> extra) => Message.fromJson({
      'id': 'm1',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'type': 'text',
      'content': 'hi',
      'transcript_status': 'none',
      'created_at': '2026-11-08T10:00:00Z',
      'seq': 4,
      ...extra,
    });

void main() {
  test('reply_to / forwarded / mentions / starred parse and round-trip', () {
    final m = _msg({
      'reply_to_id': 'm0',
      'reply_to': {'id': 'm0', 'sender_id': 'u2', 'type': 'image', 'preview': 'Photo'},
      'forwarded': true,
      'forward_depth': 2,
      'mentions': ['u2', 'u3'],
      'starred': true,
    });
    expect(m.replyToId, 'm0');
    expect(m.replyTo!.type, MessageType.image);
    expect(m.replyTo!.preview, 'Photo');
    expect(m.forwarded, isTrue);
    expect(m.forwardDepth, 2);
    expect(m.mentions, ['u2', 'u3']);
    expect(m.starred, isTrue);
    final back = Message.fromJson(m.toJson());
    expect(back.replyTo!.senderId, 'u2');
    expect(back.starred, isTrue);
    expect(back.mentions, ['u2', 'u3']);
    // copyWith keeps everything and can flip the star.
    expect(m.copyWith(read: true).replyTo!.id, 'm0');
    expect(m.copyWith(starred: false).starred, isFalse);
  });

  test('absent batch-4 fields default safely (older cache rows)', () {
    final m = _msg({});
    expect(m.replyTo, isNull);
    expect(m.forwarded, isFalse);
    expect(m.forwardDepth, 0);
    expect(m.mentions, isEmpty);
    expect(m.starred, isFalse);
  });

  test('forward depth limit and the "many times" label', () {
    expect(_msg({'forward_depth': 4, 'forwarded': true}).canForward, isTrue);
    expect(_msg({'forward_depth': 4, 'forwarded': true}).forwardedManyTimes, isFalse);
    final deep = _msg({'forward_depth': 5, 'forwarded': true});
    expect(deep.canForward, isFalse);
    expect(deep.forwardedManyTimes, isTrue);
    expect(_msg({'type': 'system'}).canForward, isFalse);
    expect(_msg({'deleted_at': '2026-11-08T10:01:00Z'}).canForward, isFalse);
  });

  test('star / pin / reply need a live, persisted, non-system row', () {
    expect(_msg({}).canStar, isTrue);
    expect(_msg({'type': 'system'}).canStar, isFalse);
    expect(_msg({'deleted_at': '2026-11-08T10:01:00Z'}).canPin, isFalse);
    final pending = Message.pending(clientId: 'x', conversationId: 'c1', senderId: 'u1', content: 'a');
    expect(pending.canReply, isFalse);
  });

  test('ReplyPreview.of renders the quote the way the server does', () {
    expect(ReplyPreview.of(_msg({'type': 'image'})).preview, 'Photo');
    expect(ReplyPreview.of(_msg({'type': 'voice_note'})).preview, 'Voice note');
    expect(ReplyPreview.of(_msg({'type': 'file', 'file_name': 'ct.pdf'})).preview, 'ct.pdf');
    expect(ReplyPreview.of(_msg({'deleted_at': '2026-11-08T10:01:00Z'})).preview, 'Message deleted');
    expect(ReplyPreview.of(_msg({'content': 'x' * 200})).preview!.length, 140);
  });

  test('a pending reply carries its quote; the outbox entry keeps the id', () {
    final q = ReplyPreview.of(_msg({}));
    final p = Message.pending(clientId: 'cid', conversationId: 'c1', senderId: 'me', content: 're', replyTo: q);
    expect(p.replyToId, 'm1');
    expect(p.replyTo!.preview, 'hi');
    final e = OutboxEntry(clientId: 'cid', conversationId: 'c1', content: 're', createdAt: DateTime.now(), replyToId: 'm1');
    expect(OutboxEntry.fromMap(e.toMap()).replyToId, 'm1');
  });

  test('StarredMessage and LinkPreview parse', () {
    final s = StarredMessage.fromJson({
      'message': _msg({'starred': true}).toJson(),
      'conversation_id': 'c1',
      'conversation_type': 'group',
      'conversation_name': 'Cardiology',
      'starred_at': '2026-11-08T11:00:00Z',
    });
    expect(s.conversationType, ConversationType.group);
    expect(s.conversationName, 'Cardiology');
    expect(s.message.starred, isTrue);
    final lp = LinkPreview.fromJson({'url': 'https://a.io', 'title': 'A', 'image_data_url': null});
    expect(lp.title, 'A');
    expect(lp.isEmpty, isFalse);
    expect(const LinkPreview(url: 'x').isEmpty, isTrue);
  });

  test('Conversation pinned message: parse, lapse, copyWith clears', () {
    final c = Conversation.fromJson({
      'id': 'c1',
      'type': 'direct',
      'member_ids': ['a', 'b'],
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': '2026-11-08T10:00:00Z',
      'pinned_message_id': 'm9',
      'pinned_until': '2026-11-09T10:00:00Z',
    });
    expect(c.activePinnedMessageId(DateTime.utc(2026, 11, 8)), 'm9');
    expect(c.activePinnedMessageId(DateTime.utc(2026, 11, 10)), isNull);
    final cleared = c.copyWith(pinnedMessageId: () => null, pinnedUntil: () => null);
    expect(cleared.pinnedMessageId, isNull);
    expect(Conversation.fromJson(c.toJson()).pinnedUntil, DateTime.utc(2026, 11, 9, 10));
    expect(c.copyWith(prefs: c.prefs).pinnedMessageId, 'm9');
  });

  test('Organization policies default to permissive', () {
    final o = Organization.fromJson({
      'id': 'o1',
      'name': 'Clinic',
      'invite_code': 'ABC',
      'status': 'active',
      'created_at': '2026-11-01T00:00:00Z',
      'policies': {'allow_copy': false},
    });
    expect(o.policies.allowCopy, isFalse);
    expect(o.policies.allowForwardOutsideOrg, isTrue);
    expect(OrgPolicies.fromJson(null).allowCopy, isTrue);
  });

  test('batch 4 WS events parse', () {
    expect(WsEventServer.fromWire('message_pinned'), WsEventServer.messagePinned);
    expect(WsEventServer.fromWire('message_unpinned'), WsEventServer.messageUnpinned);
    expect(WsEventServer.fromWire('message_starred'), WsEventServer.messageStarred);
    expect(ReportReason.fromWire('phi_misuse'), ReportReason.phiMisuse);
    expect(ReportReason.fromWire('bogus'), ReportReason.other);
  });
}
