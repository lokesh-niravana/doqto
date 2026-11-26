import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/tokens/colors.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/ui/widgets/doctor_avatar.dart';
import 'package:doqto_app/ui/widgets/link_preview_card.dart';
import 'package:doqto_app/ui/widgets/message_bubble.dart';
import 'package:doqto_app/ui/widgets/poll_bubble.dart';
import 'package:doqto_app/ui/widgets/quote_strip.dart';
import 'package:doqto_app/ui/widgets/reactions.dart';

/// Human Interface Guidelines guards for the chat widgets: 44pt targets,
/// VoiceOver names for state that is otherwise only drawn, and readable
/// secondary text on a sent bubble.
void main() {
  Future<void> pump(WidgetTester tester, Widget w) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: w))));

  group('touch targets', () {
    testWidgets('the Edited link answers anywhere in a 44pt square', (tester) async {
      var taps = 0;
      await pump(
        tester,
        MessageBubble(
          text: 'hello there, this was changed',
          isMine: false,
          timestamp: DateTime(2026, 9, 5, 10),
          edited: true,
          onEditedTap: () => taps++,
        ),
      );
      final area = find.byKey(const ValueKey('edited-tap-area'));
      expect(tester.getSize(area), const Size(44, 44));
      // 14pt above the label's own line of text: a miss before.
      final label = tester.getRect(find.text(Strings.chatEdited));
      await tester.tapAt(Offset(label.center.dx, label.top - 14));
      expect(taps, 1);
      // And the label itself still answers exactly once.
      await tester.tap(find.text(Strings.chatEdited), warnIfMissed: false);
      expect(taps, 2);
    });

    testWidgets('an edited bubble is the same size as an unedited one plus its label', (tester) async {
      await pump(
        tester,
        MessageBubble(text: 'hello', isMine: false, timestamp: DateTime(2026, 9, 5, 10), edited: true, onEditedTap: () {}),
      );
      final edited = tester.getSize(find.byType(MessageBubble)).height;
      await pump(tester, MessageBubble(text: 'hello', isMine: false, timestamp: DateTime(2026, 9, 5, 10)));
      expect(tester.getSize(find.byType(MessageBubble)).height, edited, reason: 'the tap area must not grow the row');
    });

    testWidgets('reaction pill tap area is 44pt tall', (tester) async {
      await pump(
        tester,
        ReactionPills(me: 'me', reactions: const [MessageReaction(emoji: '👍', userIds: ['a'])], onTap: () {}),
      );
      final size = tester.getSize(find.byKey(const ValueKey('reaction-pills')));
      expect(size.height, greaterThanOrEqualTo(44));
      expect(size.width, greaterThanOrEqualTo(44));
    });

    testWidgets('poll options and the composer close buttons are at least 44pt', (tester) async {
      final poll = PollData.fromJson({
        'question': 'Lunch?',
        'multiple': false,
        'options': [
          {'id': 'o1', 'position': 0, 'text': 'Pizza', 'voter_ids': <String>[]},
          {'id': 'o2', 'position': 1, 'text': 'Sushi', 'voter_ids': ['me']},
        ],
      });
      final m = Message.fromJson({
        'id': 'q',
        'conversation_id': 'c1',
        'sender_id': 'them',
        'type': 'poll',
        'created_at': '2026-11-08T10:00:00Z',
      });
      await pump(tester, PollBubble(message: m, poll: poll, isMine: false, me: 'me', onVote: (_) {}));
      expect(tester.getSize(find.byKey(const ValueKey('poll-opt-o1'))).height, greaterThanOrEqualTo(44));

      await pump(
        tester,
        QuoteStrip(quote: null, senderName: 'Dr A', isMine: false, onClose: () {}),
      );
      final close = tester.getSize(find.byKey(const ValueKey('quote-close')));
      expect(close.width, greaterThanOrEqualTo(44));
      expect(close.height, greaterThanOrEqualTo(44));
      expect(find.byTooltip(Strings.chatCancelReply), findsOneWidget);

      await pump(
        tester,
        LinkPreviewView(
          preview: LinkPreview.fromJson({'url': 'https://example.org/a', 'title': 'A title'}),
          isMine: false,
          onClose: () {},
        ),
      );
      final remove = tester.getSize(find.byKey(const ValueKey('link-preview-close')));
      expect(remove.width, greaterThanOrEqualTo(44));
      expect(remove.height, greaterThanOrEqualTo(44));
      expect(find.byTooltip(Strings.chatRemoveLinkPreview), findsOneWidget);
    });
  });

  group('VoiceOver', () {
    testWidgets('status ticks say sent / delivered / read', (tester) async {
      final handle = tester.ensureSemantics();
      Future<void> tick({bool delivered = false, bool read = false, MessageStatus status = MessageStatus.sent}) => pump(
            tester,
            MessageStatusTick(status: status, delivered: delivered, read: read, idleColor: Colors.white),
          );
      await tick();
      expect(find.bySemanticsLabel(Strings.tickSent), findsOneWidget);
      await tick(delivered: true);
      expect(find.bySemanticsLabel(Strings.tickDelivered), findsOneWidget);
      await tick(delivered: true, read: true);
      expect(find.bySemanticsLabel(Strings.tickRead), findsOneWidget);
      await tick(status: MessageStatus.failed);
      expect(find.bySemanticsLabel(Strings.tickFailed), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a poll option is a radio with its state and tally', (tester) async {
      final handle = tester.ensureSemantics();
      final poll = PollData.fromJson({
        'question': 'Lunch?',
        'multiple': false,
        'options': [
          {'id': 'o1', 'position': 0, 'text': 'Pizza', 'voter_ids': <String>[]},
          {'id': 'o2', 'position': 1, 'text': 'Sushi', 'voter_ids': ['me']},
        ],
      });
      final m = Message.fromJson({
        'id': 'q',
        'conversation_id': 'c1',
        'sender_id': 'them',
        'type': 'poll',
        'created_at': '2026-11-08T10:00:00Z',
      });
      await pump(tester, PollBubble(message: m, poll: poll, isMine: false, me: 'me', onVote: (_) {}));
      final mine = tester.getSemantics(find.byKey(const ValueKey('poll-opt-o2')));
      expect(mine.label, 'Sushi, 1 ${Strings.pollVote}');
      final data = mine.getSemanticsData();
      expect(data.flagsCollection.isChecked, CheckedState.isTrue);
      expect(data.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      expect(data.flagsCollection.isButton, isTrue);
      final other = tester.getSemantics(find.byKey(const ValueKey('poll-opt-o1'))).getSemanticsData();
      expect(other.flagsCollection.isChecked, CheckedState.isFalse);
      handle.dispose();
    });

    testWidgets('the online dot, the away dot and the selection check have names', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, DoctorAvatar(initials: 'AB', presence: PresenceStatusDot.online()));
      expect(find.bySemanticsLabel(Strings.a11yOnline), findsOneWidget);
      await pump(tester, DoctorAvatar(initials: 'AB', presence: PresenceStatusDot.away()));
      expect(find.bySemanticsLabel(Strings.a11yOnline), findsNothing);
      expect(find.bySemanticsLabel(Strings.a11yAway), findsOneWidget);
      await pump(tester, const DoctorAvatar(initials: 'AB', isSelected: true));
      expect(find.bySemanticsLabel(Strings.a11ySelected), findsOneWidget);
      handle.dispose();
    });
  });

  group('contrast', () {
    testWidgets('time on a sent bubble is drawn at 0.93 alpha or more', (tester) async {
      await pump(
        tester,
        MessageBubble(text: 'hi', isMine: true, timestamp: DateTime(2026, 9, 5, 10), forwardedLabel: 'Forwarded'),
      );
      final time = tester.widget<Text>(find.text(DateFormat.jm().format(DateTime(2026, 9, 5, 10))));
      expect(time.style!.color!.a, greaterThanOrEqualTo(0.93));
      final fwd = tester.widget<Text>(find.text('Forwarded'));
      expect(fwd.style!.color!.a, greaterThanOrEqualTo(0.93));
      final tick = tester.widget<MessageStatusTick>(find.byType(MessageStatusTick));
      expect(tick.idleColor.a, greaterThanOrEqualTo(0.93));
    });

    testWidgets('group sender names never use the bright teal or amber fills', (tester) async {
      for (var i = 0; i < AppColors.avatarCycle.length; i++) {
        await pump(
          tester,
          MessageBubble(text: 'hi', isMine: false, timestamp: DateTime(2026, 9, 5, 10), senderName: 'Dr Name', senderColorIndex: i),
        );
        final c = tester.widget<Text>(find.text('Dr Name')).style!.color;
        expect(c, isNot(AppColors.medTeal));
        expect(c, isNot(AppColors.amber));
      }
    });
  });
}
