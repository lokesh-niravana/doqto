import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/repositories/network_repository.dart';
import 'package:doqto_app/ui/screens/settings/privacy_screen.dart';

/// Records every PATCH; `fail` makes the next one throw so the optimistic
/// flip has to roll back.
class _Repo extends NetworkRepository {
  _Repo() : super(ApiClient());
  PrivacySettings current = PrivacySettings.defaults;
  final patches = <Map<String, dynamic>>[];
  bool fail = false;

  @override
  Future<PrivacySettings> getPrivacy() async => current;

  @override
  Future<PrivacySettings> patchPrivacy(Map<String, dynamic> patch) async {
    patches.add(patch);
    if (fail) throw ApiException('boom', status: 500);
    current = PrivacySettings.fromJson({...current.toJson(), ...patch});
    return current;
  }
}

late _Repo _repo;

Widget app() => ProviderScope(
      overrides: [networkRepositoryProvider.overrideWithValue(_repo)],
      child: const MaterialApp(home: PrivacyScreen()),
    );

Future<void> open(WidgetTester tester) async {
  await tester.pumpWidget(app());
  await tester.pumpAndSettle();
}

Future<void> reveal(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(find.byKey(key), 120,
      scrollable: find.descendant(
          of: find.byKey(const ValueKey('privacy-list')),
          matching: find.byType(Scrollable)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => _repo = _Repo());

  testWidgets('renders every row with the server values', (tester) async {
    _repo.current = PrivacySettings.defaults.copyWith(
      lastSeenVisibility: LastSeenVisibility.nobody,
      readReceipts: false,
      defaultDisappearSec: () => 604800,
    );
    await open(tester);
    expect(find.text(Strings.privacyLastSeenNobody), findsOneWidget);
    final sw = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('privacy-switch-read_receipts')));
    expect(sw.value, isFalse);
    await reveal(tester, const ValueKey('privacy-row-default_disappear_sec'));
    expect(find.text('7 days'), findsOneWidget);
    await reveal(tester, const ValueKey('privacy-row-blocked'));
    expect(find.byKey(const ValueKey('privacy-row-blocked')), findsOneWidget);
  });

  testWidgets('a switch sends a one-field PATCH and flips at once', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('privacy-switch-read_receipts')));
    await tester.pump(); // optimistic frame, before the _repo answers
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const ValueKey('privacy-switch-read_receipts')))
            .value,
        isFalse);
    await tester.pumpAndSettle();
    expect(_repo.patches, [
      {'read_receipts': false}
    ]);
  });

  testWidgets('a radio sheet picks a value and PATCHes only that field',
      (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('privacy-row-last_seen_visibility')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('privacy-opt-last_seen_visibility-nobody')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('privacy-opt-last_seen_visibility-nobody')));
    await tester.pumpAndSettle();
    expect(_repo.patches, [
      {'last_seen_visibility': 'nobody'}
    ]);
    expect(find.text(Strings.privacyLastSeenNobody), findsOneWidget);
    // Picking the current value again is a no-op.
    await tester.tap(find.byKey(const ValueKey('privacy-row-last_seen_visibility')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('privacy-opt-last_seen_visibility-nobody')));
    await tester.pumpAndSettle();
    expect(_repo.patches.length, 1);
  });

  testWidgets('timer "Off" sends null', (tester) async {
    _repo.current = PrivacySettings.defaults.copyWith(defaultDisappearSec: () => 86400);
    await open(tester);
    await reveal(tester, const ValueKey('privacy-row-default_disappear_sec'));
    await tester.tap(find.byKey(const ValueKey('privacy-row-default_disappear_sec')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('privacy-opt-default_disappear_sec-off')));
    await tester.pumpAndSettle();
    expect(_repo.patches, [
      {'default_disappear_sec': null}
    ]);
  });

  testWidgets('a refused save rolls the switch back and says so', (tester) async {
    _repo.fail = true;
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('privacy-switch-read_receipts')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const ValueKey('privacy-switch-read_receipts')))
            .value,
        isTrue,
        reason: 'rolled back');
    expect(find.text(Strings.privacySaveFailed), findsOneWidget);
  });
}
