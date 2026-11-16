import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/ui/widgets/emoji_picker_sheet.dart';
import 'package:doqto_app/ui/widgets/reactions.dart';

/// In-memory picker memory (the real one lives in a Hive box).
class _MemCache extends ChatCache {
  final recent = <String>[];
  int? tone;
  @override
  List<String> recentEmoji() => List.of(recent);
  @override
  Future<void> pushRecentEmoji(String emoji) async {
    recent
      ..remove(emoji)
      ..insert(0, emoji);
  }

  @override
  int? skinTone() => tone;
  @override
  Future<void> setSkinTone(int? t) async => tone = t;
}

/// Small fixed catalog so tests don't depend on the 88 KB asset.
class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final data = utf8.encode(jsonEncode({
      'unicode': '14.0',
      'groups': [
        {
          'name': 'Smileys & Emotion',
          'emoji': [
            {'e': '😀', 'n': 'grinning face'},
            {'e': '😂', 'n': 'face with tears of joy'},
          ],
        },
        {
          'name': 'People & Body',
          'emoji': [
            {'e': '👏', 'n': 'clapping hands', 'v': ['👏🏻', '👏🏼', '👏🏽', '👏🏾', '👏🏿']},
          ],
        },
      ],
    }));
    return ByteData.sublistView(Uint8List.fromList(data));
  }
}

void main() {
  Future<void> pump(WidgetTester tester, Widget w) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: w))),
      );

  group('ReactionTray', () {
    testWidgets('shows the six quick reactions plus more, picks one', (tester) async {
      String? picked;
      var more = 0;
      await pump(
        tester,
        ReactionTray(current: null, onPick: (e) => picked = e, onMore: () => more++),
      );
      for (final e in kQuickReactions) {
        expect(find.byKey(ValueKey('reaction-pick-$e')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('reaction-pick-😂')));
      expect(picked, '😂');
      await tester.tap(find.byKey(const ValueKey('reaction-more')));
      expect(more, 1);
    });

    testWidgets('a custom current reaction gets its own selected slot', (tester) async {
      await pump(tester, ReactionTray(current: '🔥', onPick: (_) {}, onMore: () {}));
      expect(find.byKey(const ValueKey('reaction-pick-🔥')), findsOneWidget);
      expect(find.byKey(const ValueKey('reaction-more')), findsOneWidget);
    });

    testWidgets('fits a 320pt-wide phone without overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(
        tester,
        FittedBox(
          fit: BoxFit.scaleDown,
          child: ReactionTray(current: '🔥', onPick: (_) {}, onMore: () {}),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('ReactionPills', () {
    testWidgets('top three emoji and the total', (tester) async {
      var taps = 0;
      await pump(
        tester,
        ReactionPills(
          me: 'me',
          onTap: () => taps++,
          reactions: const [
            MessageReaction(emoji: '👍', userIds: ['a', 'b']),
            MessageReaction(emoji: '❤️', userIds: ['me']),
            MessageReaction(emoji: '😂', userIds: ['c']),
            MessageReaction(emoji: '🙏', userIds: ['d']),
          ],
        ),
      );
      expect(find.text('👍❤️😂'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reaction-pills')));
      expect(taps, 1);
    });

    testWidgets('one reaction shows no count; empty shows nothing', (tester) async {
      await pump(
        tester,
        const ReactionPills(me: 'me', reactions: [MessageReaction(emoji: '👍', userIds: ['a'])]),
      );
      expect(find.byKey(const ValueKey('reaction-total')), findsNothing);
      await pump(tester, const ReactionPills(me: 'me', reactions: []));
      expect(find.byKey(const ValueKey('reaction-pills')), findsNothing);
    });

    testWidgets('screen reader label names the reactions', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        ReactionPills(
          me: 'me',
          onTap: () {},
          reactions: const [MessageReaction(emoji: '👍', userIds: ['a', 'b'])],
        ),
      );
      expect(
        find.bySemanticsLabel(RegExp(r'Reactions: 2 thumbs up')),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('who reacted', () {
    testWidgets('my row first, tap removes', (tester) async {
      var removed = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showWhoReactedSheet(
                context: ctx,
                me: 'me',
                reactions: const [
                  MessageReaction(emoji: '👍', userIds: ['bob', 'me']),
                ],
                nameFor: (u) => u == 'bob' ? 'Dr Bob' : '?',
                colorFor: (_) => 0,
                onRemoveMine: () => removed++,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('All 2'), findsOneWidget);
      final you = tester.getTopLeft(find.byKey(const ValueKey('who-reacted-me')).first);
      final bob = tester.getTopLeft(find.byKey(const ValueKey('who-reacted-bob')).first);
      expect(you.dy, lessThan(bob.dy));
      await tester.tap(find.text('Tap to remove').first);
      await tester.pumpAndSettle();
      expect(removed, 1);
    });
  });

  group('EmojiPickerSheet', () {
    Future<String?> open(WidgetTester tester, _MemCache cache) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<String>(
                  context: ctx,
                  isScrollControlled: true,
                  builder: (_) => EmojiPickerSheet(cache: cache, bundle: _Bundle()),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('search finds by name, pick returns it and records recent', (tester) async {
      final cache = _MemCache();
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<String>(
                  context: ctx,
                  isScrollControlled: true,
                  builder: (_) => EmojiPickerSheet(cache: cache, bundle: _Bundle()),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'clap');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('emoji-👏')), findsOneWidget);
      expect(find.byKey(const ValueKey('emoji-😀')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('emoji-👏')));
      await tester.pumpAndSettle();
      expect(result, '👏');
      expect(cache.recent, ['👏']);
    });

    testWidgets('no match shows an empty state', (tester) async {
      await open(tester, _MemCache());
      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('No emoji found'), findsOneWidget);
    });

    testWidgets('remembered skin tone applies to tone-capable emoji', (tester) async {
      await open(tester, _MemCache()..tone = 2);
      await tester.enterText(find.byType(TextField), 'clapping');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('emoji-👏🏽')), findsOneWidget);
    });

    // CLAUDE.md keyboard rule: the picker's search field must let go of the
    // keyboard on a tap outside it.
    testWidgets('search field: tap outside dismisses the keyboard', (tester) async {
      await open(tester, _MemCache());
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      // Inside the sheet but outside the field: the sheet stays, the keyboard goes.
      await tester.tap(find.text('No emoji found'));
      await tester.pumpAndSettle();
      expect(find.text('No emoji found'), findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
    });
  });

  test('the bundled asset parses and stays inside Unicode 14', () {
    final groups = EmojiCatalog.parse(
      // Reading the real file keeps the asset honest.
      File('assets/emoji/emoji.json').readAsStringSync(),
    );
    expect(groups.length, 9);
    final all = [for (final g in groups) ...g.emoji];
    expect(all.length, greaterThan(1800));
    expect(all.any((e) => e.emoji == '🫠'), isTrue, reason: 'melting face is 14.0');
    expect(all.any((e) => e.emoji == '🫨'), isFalse, reason: 'shaking face is 15.0');
    expect(EmojiCatalog.search(groups, 'thumbs up').first.emoji, '👍');
  });
}
