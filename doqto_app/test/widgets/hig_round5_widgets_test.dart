import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/chat_theme.dart';
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/theme.dart';
import 'package:doqto_app/core/tokens/colors.dart';
import 'package:doqto_app/core/utils/error_messages.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/services/auth_broker.dart';
import 'package:doqto_app/state/app_lock_state.dart';
import 'package:doqto_app/ui/screens/chat/poll_create_sheet.dart';
import 'package:doqto_app/ui/widgets/app_lock_gate.dart';
import 'package:doqto_app/ui/widgets/app_skeleton.dart';
import 'package:doqto_app/ui/widgets/attachment_bubbles.dart';
import 'package:doqto_app/ui/widgets/inline_error.dart';
import 'package:doqto_app/ui/widgets/message_bubble.dart';
import 'package:doqto_app/ui/widgets/phone_field.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';
import 'package:doqto_app/ui/widgets/reactions.dart';
import 'package:doqto_app/ui/widgets/step_flow.dart';
import 'package:doqto_app/ui/widgets/swipe_action_row.dart';

// Human Interface Guidelines, round 5 (set A): state that is said as well as
// drawn, text that survives any background, errors as sentences.

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('sign-in errors (V7)', () {
    test('known Firebase codes become sentences, never SDK text', () {
      const raw = 'The SMS verification code used to create the phone auth credential is invalid.';
      for (final code in [
        'invalid-verification-code',
        'session-expired',
        'too-many-requests',
        'invalid-phone-number',
        'network-request-failed',
        'quota-exceeded',
        'credential-already-in-use',
        'provider-already-linked',
        'user-disabled',
        'captcha-check-failed',
        'missing-client-identifier',
        'web-context-cancelled',
        'web-context-canceled',
      ]) {
        final shown = ErrorMessages.forApi(AuthBrokerException(code, raw));
        expect(shown, isNot(raw), reason: code);
        expect(shown, isNot(contains(code)), reason: code);
        expect(shown, isNot('Something went wrong. Please try again.'), reason: code);
        expect(shown.endsWith('.'), isTrue, reason: code);
      }
    });

    test('an unknown code, or a bare code as the message, falls back to the generic line', () {
      expect(
        ErrorMessages.forApi(const AuthBrokerException('internal-error', 'internal-error')),
        'Something went wrong. Please try again.',
      );
      expect(
        ErrorMessages.forApi(const AuthBrokerException('no-id-token', 'An internal error has occurred. [ x ]')),
        'Something went wrong. Please try again.',
      );
    });

    test('the hand-written app messages pass through', () {
      expect(
        ErrorMessages.forApi(const AuthBrokerException('no-authorization-code', 'Apple did not confirm the request. Try again.')),
        'Apple did not confirm the request. Try again.',
      );
      expect(
        ErrorMessages.forApi(const AuthBrokerException(
            'apple-account-mismatch', 'That Apple ID does not match this account. Sign in again to delete it.')),
        'That Apple ID does not match this account. Sign in again to delete it.',
      );
    });

    test('a stored server code is shown as a sentence or the fallback (V11)', () {
      expect(ErrorMessages.forCode('not_connected', fallback: Strings.scheduledFailed),
          'Connect with this doctor to message them.');
      expect(ErrorMessages.forCode('conversation_archived_x', fallback: Strings.scheduledFailed), Strings.scheduledFailed);
      expect(ErrorMessages.forCode(null, fallback: Strings.scheduledFailed), Strings.scheduledFailed);
    });
  });

  group('snackbars (V12)', () {
    testWidgets('white content and action text reach 4.5:1 on teal, red and the default surface', (tester) async {
      final theme = AppTheme.light();
      final content = theme.snackBarTheme.contentTextStyle!.color!;
      final action = theme.snackBarTheme.actionTextColor!;
      for (final bg in [AppColors.medBlue, AppColors.red, theme.colorScheme.inverseSurface]) {
        expect(_contrast(content, bg), greaterThanOrEqualTo(4.5), reason: '$bg');
        expect(_contrast(action, bg), greaterThanOrEqualTo(4.5), reason: '$bg');
      }
    });
  });

  group('photo wallpaper labels (V2)', () {
    test('every label colour reaches 4.5:1 on the pill surface', () {
      for (var i = 0; i < AppColors.avatarCycle.length; i++) {
        expect(_contrast(senderNameColor(i), AppColors.surface), greaterThanOrEqualTo(4.5), reason: 'sender $i');
      }
      expect(_contrast(AppColors.textSecondary, AppColors.surface), greaterThanOrEqualTo(4.5));
      expect(_contrast(AppColors.textMuted, AppColors.surface), greaterThanOrEqualTo(4.5));
    });

    testWidgets('no wallpaper photo: the label is untouched', (tester) async {
      await tester.pumpWidget(_wrap(const WallpaperLabel(child: Text('Dr. A'))));
      expect(find.byKey(const ValueKey('wallpaper-label')), findsNothing);
      expect(find.text('Dr. A'), findsOneWidget);
    });
  });

  group('AppButton (W2)', () {
    testWidgets('keeps its name while loading', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(AppButton(label: 'Unlock', loading: true, onPressed: () {})));
      await tester.pump();
      expect(find.bySemanticsLabel('Unlock'), findsOneWidget);
      expect(tester.getSemantics(find.bySemanticsLabel('Unlock')).flagsCollection.isButton, isTrue);
      handle.dispose();
    });
  });

  testWidgets('SkeletonList announces "Loading" as one node (W3)', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_wrap(const SkeletonList(rows: 3)));
    expect(find.bySemanticsLabel(Strings.loading), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel(Strings.loading)).flagsCollection.isLiveRegion, isTrue);
    handle.dispose();
  });

  testWidgets('InlineError is a live region (W11)', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_wrap(const InlineError('Wrong code.')));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.text('Wrong code.')).flagsCollection.isLiveRegion, isTrue);
    handle.dispose();
  });

  group('PhoneField (W12)', () {
    testWidgets('the field is one node named "Phone number"; the pill is a named button', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(PhoneField(onChanged: (_) {})));
      await tester.pump();
      final field = tester.getSemantics(find.byType(TextField));
      expect(field.label, 'Phone number');
      expect(field.flagsCollection.isTextField, isTrue);
      expect(find.semantics.byLabel('Phone number'), findsOneWidget);
      expect(find.text('555 555 0100'), findsOneWidget, reason: 'the example is still drawn');
      final pill = find.bySemanticsLabel(RegExp(r'^Country code, United States \+1$'));
      expect(pill, findsOneWidget);
      final node = tester.getSemantics(pill);
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });
  });

  testWidgets('StepFlow says which step this is (W14)', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StepFlow(
          currentStep: 1,
          stepTitles: const ['Name', 'Privacy', 'Members'],
          onNext: () {},
          child: const SizedBox(),
        ),
      ),
    ));
    expect(find.bySemanticsLabel('Step 2 of 3: Privacy'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('hidden swipe actions are not in the semantics tree until swiped (W8)', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_wrap(SizedBox(
      height: 72,
      child: SwipeActionRow(
        trailing: SwipeAction(icon: Icons.archive, label: 'Archive', color: AppColors.medBlue, onTap: () {}),
        child: const SizedBox(height: 72, width: double.infinity, child: Text('row')),
      ),
    )));
    expect(find.bySemanticsLabel('Archive'), findsNothing);
    await tester.drag(find.text('row'), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Archive'), findsOneWidget);
    handle.dispose();
  });

  group('status tick (W16)', () {
    IconData glyph(WidgetTester tester, String key) => tester.widget<Icon>(find.byKey(ValueKey(key))).icon!;

    testWidgets('sent, delivered and read are three different glyphs', (tester) async {
      Future<IconData> build({required bool delivered, required bool read, required String key}) async {
        await tester.pumpWidget(_wrap(MessageStatusTick(
          status: MessageStatus.sent,
          delivered: delivered,
          read: read,
          idleColor: AppColors.white,
        )));
        await tester.pumpAndSettle();
        return glyph(tester, key);
      }

      final sent = await build(delivered: false, read: false, key: 'tick-sent-sent');
      final delivered = await build(delivered: true, read: false, key: 'tick-sent-delivered');
      final read = await build(delivered: true, read: true, key: 'tick-sent-read');
      expect({sent, delivered, read}, hasLength(3));
    });
  });

  group('reaction tray (W17, W20)', () {
    testWidgets('my reaction carries a teal ring, not only a pale fill', (tester) async {
      await tester.pumpWidget(_wrap(ReactionTray(current: '👍', onPick: (_) {}, onMore: () {})));
      await tester.pumpAndSettle();
      BoxDecoration deco(String e) => tester
          .widget<AnimatedContainer>(
              find.descendant(of: find.byKey(ValueKey('reaction-pick-$e')), matching: find.byType(AnimatedContainer)))
          .decoration! as BoxDecoration;
      final mine = deco('👍').border! as Border;
      expect(mine.top.color, AppColors.medBlue);
      expect(mine.top.width, 1.5);
      expect(_contrast(AppColors.medBlue, AppColors.white), greaterThanOrEqualTo(3));
      expect(deco('😂').border, isNull);
    });

    testWidgets('emoji stay inside their circles at 3x text', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: Scaffold(body: Center(child: ReactionTray(current: null, onPick: (_) {}, onMore: () {}))),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final box = tester.getSize(find.descendant(
          of: find.byKey(const ValueKey('reaction-pick-👍')), matching: find.byType(FittedBox)));
      expect(box.width, lessThanOrEqualTo(38));
      expect(box.height, lessThanOrEqualTo(38));
    });
  });

  group('DownloadPlaceholder (W7)', () {
    testWidgets('with a semantic label it is one named button node', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(DownloadPlaceholder(
        width: 120,
        height: 120,
        label: '',
        semanticLabel: 'Photo 2 of 4. ${Strings.mediaTapToDownload}',
        onTap: () {},
      )));
      final f = find.bySemanticsLabel('Photo 2 of 4. ${Strings.mediaTapToDownload}');
      expect(f, findsOneWidget);
      final node = tester.getSemantics(f);
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.childrenCount, 0);
      handle.dispose();
    });
  });

  group('app lock gate (W1)', () {
    testWidgets('behind the privacy cover the app is not readable or tappable', (tester) async {
      final handle = tester.ensureSemantics();
      final c = ProviderContainer(overrides: [
        localAuthenticatorProvider.overrideWithValue(FakeLocalAuthenticator(result: false)),
      ]);
      addTearDown(c.dispose);
      var taps = 0;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: AppLockGate(
            child: Scaffold(body: Center(child: TextButton(onPressed: () => taps++, child: const Text('secret chat')))),
          ),
        ),
      ));
      await tester.pump();
      expect(find.semantics.byLabel('secret chat'), findsOneWidget);

      c.read(appLockProvider.notifier).onLeftForeground();
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
      expect(find.semantics.byLabel('secret chat'), findsNothing);
      await tester.tapAt(tester.getCenter(find.byType(AppLockGate)));
      expect(taps, 0);
      handle.dispose();
    });
  });

  group('poll draft (W31)', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(child: TextButton(onPressed: () => showPollCreateSheet(ctx), child: const Text('open'))),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a scrim tap on an empty sheet just closes it', (tester) async {
      await open(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(PollCreateSheet), findsNothing);
    });

    testWidgets('a scrim tap with a draft asks first; Keep editing keeps it, Discard drops it', (tester) async {
      await open(tester);
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('poll-question')), matching: find.byType(TextField)),
          'Rounds at 7?');
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text(Strings.pollDiscardTitle), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('poll-discard-keep')));
      await tester.pumpAndSettle();
      expect(find.byType(PollCreateSheet), findsOneWidget);
      expect(find.text('Rounds at 7?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('poll-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('poll-discard-confirm')));
      await tester.pumpAndSettle();
      expect(find.byType(PollCreateSheet), findsNothing);
    });
  });
}
