import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/chat_theme.dart';
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/core/tokens/colors.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/compliance.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/compliance_repository.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/ui/screens/chat/forward_picker_sheet.dart';
import 'package:doqto_app/ui/screens/compliance/scheduled_messages_sheet.dart';
import 'package:doqto_app/ui/widgets/app_chip.dart';
import 'package:doqto_app/ui/widgets/attachment_bubbles.dart';
import 'package:doqto_app/ui/widgets/inline_banner.dart';
import 'package:doqto_app/ui/widgets/message_bubble.dart';
import 'package:doqto_app/ui/widgets/quote_strip.dart';
import 'package:doqto_app/ui/widgets/stateful_action_button.dart';
import 'package:doqto_app/ui/widgets/step_flow.dart';

// Human Interface Guidelines, round 3: guards for the shared widgets and
// the chat sheets. Touch areas of 44pt, state that is spoken as well as
// drawn, contrast computed against every chat theme, and messages that
// appear where the user can see them.

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

class _Auth extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        AuthStage.signedIn,
        User.fromJson({
          'id': 'me',
          'phone': '+15550000101',
          'full_name': 'Me',
          'npi_number': '1234567893',
          'role': 'doctor',
          'created_at': '2026-09-05T00:00:00Z',
        }),
      );
}

class _Convs extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _Conns extends ConnectionsNotifier {
  @override
  Future<List<PersonCard>> build() async => [
        for (var i = 1; i <= 6; i++)
          PersonCard(
            id: 'u$i',
            fullName: 'Dr Person $i',
            headline: null,
            specialty: null,
            locationLabel: null,
            avatarColor: null,
            avatarUrl: null,
            avatarPresignedUrl: null,
            degree: ConnectionDegree.first,
            mutualCount: 0,
          ),
      ];
}

class _Scheduled extends ComplianceRepository {
  _Scheduled() : super(ApiClient());
  bool fail = false;

  @override
  Future<List<ScheduledMessage>> scheduled(String conversationId) async => [
        ScheduledMessage(
          id: 's1',
          conversationId: conversationId,
          scheduledAt: DateTime.utc(2027, 1, 1, 9),
          timezone: 'UTC',
          status: 'pending',
        ),
      ];

  @override
  Future<void> cancelScheduled(String scheduledId) async {
    if (fail) throw ApiException('boom', status: 500);
  }
}

void main() {
  group('touch areas', () {
    testWidgets('a chip with a short label is 44pt wide to touch', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(AppChip(label: 'All', onTap: () => taps++)));
      final size = tester.getSize(find.byType(AppChip));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
      // The far left edge of the area, outside the pill itself.
      final rect = tester.getRect(find.byType(AppChip));
      await tester.tapAt(Offset(rect.left + 1, rect.center.dy));
      expect(taps, 1);
    });

    testWidgets('a one-line quote inside a bubble is 44pt tall to touch', (tester) async {
      await tester.pumpWidget(_wrap(
        QuoteStrip(
          quote: const ReplyPreview(id: 'm1', senderId: 'u2', type: MessageType.text, preview: 'short'),
          senderName: 'Dr Two',
          isMine: false,
          onTap: () {},
        ),
      ));
      expect(tester.getSize(find.byType(QuoteStrip)).height, greaterThanOrEqualTo(44));
    });
  });

  group('spoken state', () {
    testWidgets('a selectable row says it is the checked radio choice', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableRow(key: const ValueKey('a'), title: 'Public', subtitle: 'Anyone', selected: true, onTap: () {}),
          SelectableRow(key: const ValueKey('b'), title: 'Private', subtitle: 'Invited', selected: false, onTap: () {}),
        ],
      )));
      final on = tester.getSemantics(find.text('Public')).getSemanticsData();
      expect(on.flagsCollection.isChecked, CheckedState.isTrue);
      expect(on.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      final off = tester.getSemantics(find.text('Private')).getSemanticsData();
      expect(off.flagsCollection.isChecked, CheckedState.isFalse);
      handle.dispose();
    });
  });

  group('contrast', () {
    testWidgets('failed and read ticks are 3:1 or better on every sent bubble', (tester) async {
      for (final (status, read) in [(MessageStatus.failed, false), (MessageStatus.sent, true)]) {
        await tester.pumpWidget(_wrap(
          MessageStatusTick(status: status, read: read, idleColor: Colors.white),
        ));
        await tester.pumpAndSettle();
        final tint = tester.widget<Icon>(find.byType(Icon)).color!;
        for (final theme in ChatTheme.all) {
          expect(_contrast(tint, theme.sent), greaterThanOrEqualTo(3.0), reason: '$status on ${theme.id}');
        }
      }
    });

    test('sender names are 4.5:1 or better on every received bubble', () {
      for (var i = 0; i < AppColors.avatarCycle.length; i++) {
        for (final theme in ChatTheme.all) {
          expect(
            _contrast(senderNameColor(i), theme.received),
            greaterThanOrEqualTo(4.5),
            reason: 'avatar colour $i on ${theme.id}',
          );
        }
      }
    });

    test('white on the photo scrim is 4.5:1 or better over a white photo', () {
      final over = Color.alphaBlend(
        AppColors.gray900.withValues(alpha: kPhotoScrimAlpha),
        Colors.white,
      );
      expect(_contrast(Colors.white, over), greaterThanOrEqualTo(4.5));
    });
  });

  group('InlineBanner', () {
    testWidgets('grows with large text instead of clipping it', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.5)),
          child: const Scaffold(
            body: Center(child: InlineBanner(tone: BannerTone.warn, text: 'heads up')),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final banner = tester.getRect(find.byType(InlineBanner));
      final label = tester.getRect(find.text('heads up'));
      expect(banner.height, greaterThan(26));
      expect(label.top, greaterThanOrEqualTo(banner.top));
      expect(label.bottom, lessThanOrEqualTo(banner.bottom));
    });
  });

  group('messages the user can see', () {
    testWidgets('a failed action button says why', (tester) async {
      await tester.pumpWidget(_wrap(
        StatefulActionButton<bool>(
          state: false,
          visuals: const {false: ActionVisual(label: 'Connect')},
          onPressed: () async => throw ApiException('boom', status: 500),
        ),
      ));
      await tester.tap(find.text('Connect').first);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('forward picker: the five-chat limit is said inside the sheet', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          authProvider.overrideWith(_Auth.new),
          conversationsProvider.overrideWith(_Convs.new),
          connectionsProvider.overrideWith(_Conns.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showForwardPicker(context, excludeConversationId: 'c0'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final sheet = find.byKey(const ValueKey('forward-picker'));
      for (var i = 1; i <= 5; i++) {
        await tester.tap(find.byKey(ValueKey('forward-target-user:u$i')));
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('forward-limit')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('forward-target-user:u6')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: sheet, matching: find.text(Strings.chatForwardLimit)),
        findsOneWidget,
        reason: 'drawn in the sheet, not under it',
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('5/${ForwardPickerSheet.max}'), findsOneWidget);

      // Making room clears the notice.
      await tester.tap(find.byKey(const ValueKey('forward-target-user:u1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('forward-limit')), findsNothing);
    });

    for (final fail in [false, true]) {
      testWidgets('scheduled sheet: cancel ${fail ? 'failure' : 'success'} is said inside the sheet', (tester) async {
        final repo = _Scheduled()..fail = fail;
        await tester.pumpWidget(ProviderScope(
          overrides: [complianceRepositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showScheduledMessagesSheet(context, 'c1'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('scheduled-cancel-s1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('scheduled-cancel-yes')));
        await tester.pumpAndSettle();

        final notice = find.descendant(
          of: find.byKey(const ValueKey('scheduled-sheet')),
          matching: find.byKey(const ValueKey('scheduled-notice')),
        );
        expect(notice, findsOneWidget, reason: 'drawn in the sheet, not under it');
        expect(find.byType(SnackBar), findsNothing);
        if (!fail) {
          expect(find.descendant(of: notice, matching: find.text(Strings.scheduledCancelled)), findsOneWidget);
          expect(find.byKey(const ValueKey('scheduled-row-s1')), findsNothing);
        } else {
          expect(find.byKey(const ValueKey('scheduled-row-s1')), findsOneWidget);
        }
      });
    }
  });
}
