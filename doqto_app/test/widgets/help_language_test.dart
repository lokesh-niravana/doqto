import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/models/app_meta.dart';
import 'package:doqto_app/data/services/url_opener.dart';
import 'package:doqto_app/state/app_meta_state.dart';
import 'package:doqto_app/state/settings_state.dart';
import 'package:doqto_app/ui/screens/settings/help_screen.dart';
import 'package:doqto_app/ui/screens/settings/language_screen.dart';

void main() {
  group('HelpScreen', () {
    late FakeUrlOpener opener;
    setUp(() => opener = FakeUrlOpener());

    Widget app({LegalLinks? links}) => ProviderScope(
          overrides: [
            urlOpenerProvider.overrideWithValue(opener),
            appVersionProvider.overrideWith((ref) async => '1.0.0+45'),
            if (links != null) legalLinksProvider.overrideWith((ref) async => links),
            if (links == null)
              legalLinksProvider.overrideWith((ref) => Future<LegalLinks>.error('offline')),
          ],
          child: const MaterialApp(home: HelpScreen()),
        );

    testWidgets('rows open the server links; version in the footer', (tester) async {
      await tester.pumpWidget(app(
        links: const LegalLinks(
          help: 'https://x/help',
          contact: 'mailto:hi@x',
          terms: 'https://x/terms',
          privacy: 'https://x/privacy',
          hipaa: 'https://x/hipaa',
        ),
      ));
      await tester.pumpAndSettle();
      for (final (key, url) in [
        ('help-centre', 'https://x/help'),
        ('help-contact', 'mailto:hi@x'),
        ('help-terms', 'https://x/terms'),
        ('help-privacy', 'https://x/privacy'),
        ('help-hipaa', 'https://x/hipaa'),
      ]) {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pump();
        expect(opener.opened.last, url);
      }
      expect(find.text('Version 1.0.0+45'), findsOneWidget);
      expect(find.byKey(const ValueKey('help-licences')), findsOneWidget);
    });

    testWidgets('offline: the compiled-in defaults still open', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('help-terms')));
      await tester.pump();
      expect(opener.opened, [LegalLinks.defaults.terms]);
    });
  });

  group('LanguageScreen', () {
    testWidgets('picking a language updates the setting; System clears it', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: LanguageScreen()),
      ));
      await tester.pumpAndSettle();
      expect(c.read(appSettingsProvider).locale, isNull);

      await tester.tap(find.byKey(const ValueKey('language-opt-es')));
      await tester.pumpAndSettle();
      expect(c.read(appSettingsProvider).locale, const Locale('es'));

      await tester.tap(find.byKey(const ValueKey('language-opt-en')));
      await tester.pumpAndSettle();
      expect(c.read(appSettingsProvider).locale, const Locale('en'));

      await tester.tap(find.byKey(const ValueKey('language-opt-system')));
      await tester.pumpAndSettle();
      expect(c.read(appSettingsProvider).locale, isNull);
    });
  });
}
