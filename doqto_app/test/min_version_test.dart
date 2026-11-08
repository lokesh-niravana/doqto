import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/models/app_meta.dart';
import 'package:doqto_app/data/services/url_opener.dart';
import 'package:doqto_app/state/app_meta_state.dart';
import 'package:doqto_app/ui/widgets/force_update_gate.dart';

const _min = MinVersion(ios: '1.0.0+50', android: '1.0.0+40', message: 'Please update.');

void main() {
  group('MinVersion.requiresUpdate', () {
    test('compares build numbers per platform', () {
      expect(_min.requiresUpdate(installedVersion: '1.0.0+45', platform: 'ios'), isTrue);
      expect(_min.requiresUpdate(installedVersion: '1.0.0+50', platform: 'ios'), isFalse);
      expect(_min.requiresUpdate(installedVersion: '1.0.0+45', platform: 'android'), isFalse);
      expect(_min.requiresUpdate(installedVersion: '1.0.0+39', platform: 'android'), isTrue);
    });

    test('unknown minimum or dev build never gates', () {
      const none = MinVersion(ios: '', android: '', message: '');
      expect(none.requiresUpdate(installedVersion: '1.0.0+1', platform: 'ios'), isFalse);
      expect(_min.requiresUpdate(installedVersion: '1.0.0', platform: 'ios'), isFalse);
      expect(MinVersion.buildNumber('1.2.3+77'), 77);
      expect(MinVersion.buildNumber('1.2.3'), 0);
    });
  });

  group('forceUpdateProvider', () {
    ProviderContainer make({MinVersion? min, String version = '1.0.0+45', String platform = 'ios'}) =>
        ProviderContainer(overrides: [
          minVersionProvider.overrideWith((ref) async => min),
          appVersionProvider.overrideWith((ref) async => version),
          platformNameProvider.overrideWithValue(platform),
        ]);

    Future<void> ready(ProviderContainer c) async {
      await c.read(minVersionProvider.future);
      await c.read(appVersionProvider.future);
    }

    test('gated below the minimum, open at or above it', () async {
      final c = make(min: _min);
      addTearDown(c.dispose);
      expect(c.read(forceUpdateProvider), isFalse, reason: 'nothing known yet');
      await ready(c);
      expect(c.read(forceUpdateProvider), isTrue);

      final ok = make(min: _min, version: '1.0.0+51');
      addTearDown(ok.dispose);
      await ready(ok);
      expect(ok.read(forceUpdateProvider), isFalse);
    });

    test('a failed fetch (null) never gates', () async {
      final c = make();
      addTearDown(c.dispose);
      await ready(c);
      expect(c.read(forceUpdateProvider), isFalse);
    });

    test('store URLs', () {
      expect(storeUrl('ios'), 'https://apps.apple.com/app/id6823733882');
      expect(storeUrl('android'), 'https://play.google.com/store/apps/details?id=com.doqto.app');
    });
  });

  testWidgets('ForceUpdateGate replaces the app and Update opens the store', (tester) async {
    final opener = FakeUrlOpener();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        minVersionProvider.overrideWith((ref) async => _min),
        appVersionProvider.overrideWith((ref) async => '1.0.0+45'),
        platformNameProvider.overrideWithValue('android'),
        urlOpenerProvider.overrideWithValue(opener),
      ],
      child: const MaterialApp(
        home: ForceUpdateGate(child: Scaffold(body: Text('the app'))),
      ),
    ));
    await tester.pump();
    expect(find.text('the app'), findsOneWidget, reason: 'open until the fetch lands');
    await tester.pumpAndSettle();
    // Android minimum is +40 and we are +45: not gated on Android.
    expect(find.text('the app'), findsOneWidget);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        minVersionProvider.overrideWith((ref) async => _min),
        appVersionProvider.overrideWith((ref) async => '1.0.0+45'),
        platformNameProvider.overrideWithValue('ios'),
        urlOpenerProvider.overrideWithValue(opener),
      ],
      child: const MaterialApp(
        home: ForceUpdateGate(child: Scaffold(body: Text('the app'))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('the app'), findsNothing);
    expect(find.byKey(const ValueKey('force-update-screen')), findsOneWidget);
    expect(find.text('Please update.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('force-update-button')));
    await tester.pump();
    expect(opener.opened, ['https://apps.apple.com/app/id6823733882']);
  });
}
