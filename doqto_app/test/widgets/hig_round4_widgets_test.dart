import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/tokens/colors.dart';
import 'package:doqto_app/ui/widgets/doctor_avatar.dart';
import 'package:doqto_app/ui/widgets/load_failed.dart';
import 'package:doqto_app/ui/widgets/media_load_failed.dart';
import 'package:doqto_app/ui/widgets/mention_controller.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';

// Human Interface Guidelines, round 4: labels that survive large text,
// state carried by more than hue, and failures that offer a way forward.

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Widget _wrap(Widget child, {double textScale = 1}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  group('AppButton', () {
    const long = 'Forward to Dr. Bartholomew Featherstonehaugh-Montgomery and 14 others';

    testWidgets('a very long label at 2x text in a 200pt box wraps and truncates, never overflows', (tester) async {
      for (final icon in [null, Icons.send_rounded]) {
        for (final expand in [false, true]) {
          await tester.pumpWidget(_wrap(
            SizedBox(width: 200, child: AppButton(label: long, icon: icon, expand: expand, onPressed: () {})),
            textScale: 2,
          ));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'icon=$icon expand=$expand');
          final size = tester.getSize(find.byType(AppButton));
          expect(size.width, lessThanOrEqualTo(200));
          expect(size.height, greaterThan(44), reason: 'two lines grow the button');
        }
      }
    });

    testWidgets('three buttons sharing a narrow row at 2x text do not overflow', (tester) async {
      await tester.pumpWidget(_wrap(
        SizedBox(
          width: 320,
          child: Row(children: [
            for (final l in ['Delete for me', 'Forward', 'Guardar en Fotos'])
              Expanded(child: AppButton(label: l, icon: Icons.star_rounded, onPressed: () {})),
          ]),
        ),
        textScale: 2,
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a short label keeps the 44pt single-line button', (tester) async {
      await tester.pumpWidget(_wrap(AppButton(label: 'Send', onPressed: () {})));
      expect(tester.getSize(find.byType(AppButton)).height, 44);
    });
  });

  group('PresenceStatusDot', () {
    test('online and away both reach 3:1 against the white ring', () {
      expect(_contrast(PresenceStatusDot.online().color, AppColors.white), greaterThanOrEqualTo(3));
      expect(_contrast(PresenceStatusDot.away().color, AppColors.white), greaterThanOrEqualTo(3));
    });

    test('away differs from online by shape, not only by hue', () {
      expect(PresenceStatusDot.online().hollow, isFalse);
      expect(PresenceStatusDot.away().hollow, isTrue);
      expect(PresenceStatusDot.online().semanticLabel, Strings.a11yOnline);
      expect(PresenceStatusDot.away().semanticLabel, Strings.a11yAway);
    });
  });

  group('DoctorAvatar', () {
    testWidgets('initials stay inside the circle at 3x text, on every size', (tester) async {
      for (final size in AvatarSize.values) {
        await tester.pumpWidget(_wrap(DoctorAvatar(initials: 'WM', size: size), textScale: 3));
        expect(tester.takeException(), isNull);
        final circle = tester.getRect(find.byType(DoctorAvatar));
        final text = tester.getRect(find.text('WM'));
        expect(circle.contains(text.topLeft) && circle.contains(text.bottomRight), isTrue, reason: '$size');
      }
    });
  });

  group('load failures', () {
    testWidgets('MediaLoadFailed says what happened and retries', (tester) async {
      var retries = 0;
      await tester.pumpWidget(_wrap(
        MediaLoadFailed(message: Strings.mediaVideoLoadFailed, onRetry: () => retries++),
      ));
      expect(find.text(Strings.mediaVideoLoadFailed), findsOneWidget);
      await tester.tap(find.text(Strings.tryAgain));
      expect(retries, 1);
      expect(tester.getSize(find.byKey(const ValueKey('media-load-retry'))).height, greaterThanOrEqualTo(44));
    });

    testWidgets('LoadFailed shows the reason with a Retry button', (tester) async {
      var retries = 0;
      await tester.pumpWidget(_wrap(LoadFailed(message: 'No connection', onRetry: () => retries++)));
      expect(find.text('No connection'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('load-failed-retry')));
      expect(retries, 1);
    });
  });

  test('strings: bulk delete reports partial success honestly', () {
    expect(Strings.chatsDeleted(1, 1), 'Deleted 1 chat.');
    expect(Strings.chatsDeleted(3, 3), 'Deleted 3 chats.');
    expect(Strings.chatsDeleted(2, 5), 'Deleted 2 of 5 chats.');
  });

  testWidgets('mention chip text reaches 4.5:1 on its tint', (tester) async {
    final c = MentionController(text: '@')..selection = const TextSelection.collapsed(offset: 1);
    c.insertMention(userId: 'u1', name: 'Ann Lee');
    late TextSpan span;
    await tester.pumpWidget(_wrap(Builder(builder: (context) {
      span = c.buildTextSpan(context: context, style: const TextStyle(), withComposing: false);
      return const SizedBox();
    })));
    final chip = span.children!.whereType<TextSpan>().firstWhere((s) => s.text == '@Ann Lee').style!;
    expect(_contrast(chip.color!, chip.backgroundColor!), greaterThanOrEqualTo(4.5));
  });
}
