import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/utils/chat_list_filters.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/conversation_prefs.dart';

Conversation _conv(
  String id, {
  String type = 'direct',
  int unread = 0,
  Map<String, dynamic>? prefs,
  String lastAt = '2026-11-08T10:00:00Z',
}) =>
    Conversation.fromJson({
      'id': id,
      'type': type,
      'member_ids': ['me', 'them'],
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': lastAt,
      'last_message_at': lastAt,
      'unread_count': unread,
      'prefs': ?prefs,
    });

void main() {
  group('ConversationPrefs', () {
    test('absent on the wire = defaults, and round-trips through JSON', () {
      final c = _conv('c1');
      expect(c.prefs, ConversationPrefs.defaults);
      expect(c.prefs.isPinned, isFalse);
      expect(c.prefs.isMuted(), isFalse);
      final full = ConversationPrefs.fromJson({
        'pinned_at': '2026-11-08T09:00:00Z',
        'archived': true,
        'muted_until': '2026-11-09T09:00:00Z',
        'custom_tone': 'chime',
        'custom_vibrate': 'short',
        'theme': 'sage',
        'wallpaper': 'w1',
        'marked_unread': true,
        'cleared_before_seq': 12,
        'hidden_until_seq': 12,
      });
      expect(ConversationPrefs.fromJson(full.toJson()), full);
      expect(Conversation.fromJson(_conv('c2', prefs: full.toJson()).toJson()).prefs, full);
    });

    test('isMuted follows the clock; the far-future sentinel is "always"', () {
      final now = DateTime.utc(2026, 11, 8, 12);
      final p = ConversationPrefs(mutedUntil: now.add(const Duration(hours: 8)));
      expect(p.isMuted(now), isTrue);
      expect(p.isMuted(now.add(const Duration(hours: 9))), isFalse);
      expect(p.isMutedAlways, isFalse);
      final always = ConversationPrefs(mutedUntil: ConversationPrefs.alwaysUntil);
      expect(always.isMuted(now), isTrue);
      expect(always.isMutedAlways, isTrue);
      expect(MuteDuration.eightHours.until(now), now.add(const Duration(hours: 8)));
      expect(MuteDuration.oneWeek.until(now), now.add(const Duration(days: 7)));
      expect(MuteDuration.always.until(now), ConversationPrefs.alwaysUntil);
    });

    test('copyWith clears nullable fields through a thunk', () {
      final p = ConversationPrefs(pinnedAt: DateTime.utc(2026), archived: true);
      expect(p.copyWith(pinnedAt: () => null).pinnedAt, isNull);
      expect(p.copyWith(archived: false).pinnedAt, p.pinnedAt);
    });
  });

  group('chat list helpers', () {
    final pinnedLate = _conv('p2',
        prefs: {'pinned_at': '2026-11-08T08:00:00Z'}, lastAt: '2026-11-01T00:00:00Z');
    final pinnedEarly = _conv('p1',
        prefs: {'pinned_at': '2026-11-08T07:00:00Z'}, lastAt: '2026-11-02T00:00:00Z');
    final newest = _conv('n', unread: 2, lastAt: '2026-11-08T10:00:00Z');
    final older = _conv('o', lastAt: '2026-11-07T10:00:00Z');
    final group = _conv('g', type: 'group', lastAt: '2026-11-06T10:00:00Z');
    final archived = _conv('a', unread: 1, prefs: {'archived': true}, lastAt: '2026-11-08T11:00:00Z');
    final marked = _conv('m', prefs: {'marked_unread': true}, lastAt: '2026-11-05T10:00:00Z');
    final muted = _conv('mu', unread: 5,
        prefs: {'muted_until': '9999-12-31T00:00:00Z'}, lastAt: '2026-11-04T10:00:00Z');
    final all = [older, archived, group, newest, pinnedLate, muted, marked, pinnedEarly];

    test('pinned first in pin order, then recency', () {
      expect(sortConversations(all).map((c) => c.id).toList(),
          ['p1', 'p2', 'a', 'n', 'o', 'g', 'm', 'mu']);
    });

    test('filters', () {
      final sorted = sortConversations(all);
      expect(applyChatFilter(sorted, ChatFilter.all).map((c) => c.id),
          ['p1', 'p2', 'n', 'o', 'g', 'm', 'mu']);
      expect(applyChatFilter(sorted, ChatFilter.unread).map((c) => c.id), ['n', 'm', 'mu']);
      expect(applyChatFilter(sorted, ChatFilter.groups).map((c) => c.id), ['g']);
      expect(applyChatFilter(sorted, ChatFilter.archived).map((c) => c.id), ['a']);
    });

    test('unread total skips archived + muted and counts a hand-set dot once', () {
      // newest 2 + marked 1; archived (1) and muted (5) are left out.
      expect(unreadTotalOf(all, DateTime.utc(2026, 11, 8)), 3);
      expect(isConversationUnread(marked), isTrue);
      expect(isConversationUnread(older), isFalse);
    });
  });
}
