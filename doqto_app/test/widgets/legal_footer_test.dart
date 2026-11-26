import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/models/app_meta.dart';
import 'package:doqto_app/data/services/url_opener.dart';
import 'package:doqto_app/state/app_meta_state.dart';
import 'package:doqto_app/ui/screens/auth/login_screen.dart';
import 'package:doqto_app/ui/widgets/legal_footer.dart';

// App Store guideline 1.2 / 5.1.1: anyone creating an account or signing in
// can read and agrees to the Terms and Privacy Policy. The footer sits on the
// login screen (and registration, covered by registration_form_test) and
// each document opens in the browser from the links the backend publishes.
void main() {
  late FakeUrlOpener opener;

  Future<void> pump(WidgetTester tester, Widget home) => tester.pumpWidget(
        ProviderScope(
          overrides: [
            urlOpenerProvider.overrideWithValue(opener),
            legalLinksProvider.overrideWith(
              (_) async => const LegalLinks(
                help: 'https://doqto.ai/support',
                contact: 'mailto:support@doqto.ai',
                terms: 'https://doqto.ai/terms?v=test',
                privacy: 'https://doqto.ai/privacy?v=test',
                hipaa: 'https://doqto.ai/hipaa',
              ),
            ),
          ],
          child: MaterialApp(home: home),
        ),
      );

  setUp(() => opener = FakeUrlOpener());

  /// Taps the link button labelled [label] inside the footer.
  Future<void> tapSpan(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('legal-footer')),
      matching: find.widgetWithText(TextButton, label),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('login shows the agreement line with both documents', (tester) async {
    await pump(tester, const LoginScreen());
    await tester.pumpAndSettle();

    expect(find.byType(LegalFooter), findsOneWidget);
    expect(
      find.textContaining(Strings.legalByContinuing.trim(), findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining(Strings.legalTerms, findRichText: true), findsOneWidget);
    expect(find.textContaining(Strings.legalPrivacy, findRichText: true), findsOneWidget);
  });

  testWidgets('the links open the published terms and privacy URLs', (tester) async {
    await pump(tester, const Scaffold(body: Center(child: LegalFooter())));
    await tester.pumpAndSettle();

    await tapSpan(tester, Strings.legalTerms);
    await tapSpan(tester, Strings.legalPrivacy);
    expect(opener.opened, [
      'https://doqto.ai/terms?v=test',
      'https://doqto.ai/privacy?v=test',
    ]);
  });

  testWidgets('each link is at least 44pt in both directions', (tester) async {
    await pump(tester, const Scaffold(body: Center(child: LegalFooter())));
    await tester.pumpAndSettle();

    for (final label in [Strings.legalTerms, Strings.legalPrivacy]) {
      final size = tester.getSize(find.widgetWithText(TextButton, label));
      expect(size.height, greaterThanOrEqualTo(44), reason: label);
      expect(size.width, greaterThanOrEqualTo(44), reason: label);
    }
  });

  testWidgets('falls back to the built-in links before the backend answers', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          urlOpenerProvider.overrideWithValue(opener),
          // Never completes: the screen must not wait for it.
          legalLinksProvider.overrideWith((_) => Completer<LegalLinks>().future),
        ],
        child: const MaterialApp(home: Scaffold(body: Center(child: LegalFooter()))),
      ),
    );
    await tester.pump();

    await tapSpan(tester, Strings.legalTerms);
    expect(opener.opened, [LegalLinks.defaults.terms]);
  });

  testWidgets('a failed open tells the user instead of doing nothing', (tester) async {
    opener.result = false;
    await pump(tester, const Scaffold(body: Center(child: LegalFooter())));
    await tester.pumpAndSettle();

    await tapSpan(tester, Strings.legalPrivacy);
    expect(find.text(Strings.legalOpenFailed), findsOneWidget);
  });
}
