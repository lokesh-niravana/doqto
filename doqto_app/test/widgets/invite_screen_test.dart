import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/repositories/network_repository.dart';
import 'package:doqto_app/ui/screens/people/invite_screen.dart';

class _Repo extends NetworkRepository {
  final lookups = <String>[];
  final invited = <String>[];
  _Repo() : super(ApiClient());

  @override
  Future<List<NpiHit>> npiLookup(String q, {String? state}) async {
    lookups.add('$q/$state');
    NpiHit hit(String npi, String name, NpiStatus s) => NpiHit(
        npi: npi,
        name: name,
        specialty: 'Family Medicine',
        location: 'Quincy, MA',
        status: s,
        userId: s == NpiStatus.invite ? null : 'u$npi');
    return [
      hit('1000000001', 'Anika Patel, MD', NpiStatus.message),
      hit('1000000002', 'Rohan Patel, MD', NpiStatus.requested),
      hit('1000000003', 'Priya Patel, MD', NpiStatus.connect),
      hit('1000000004', 'Neel Patel, MD', NpiStatus.invite),
    ];
  }

  @override
  Future<void> recordInvite(String npi) async => invited.add(npi);
}

void main() {
  late _Repo repo;
  late List<String> shared;

  Future<void> pump(WidgetTester tester, {String q = ''}) async {
    repo = _Repo();
    shared = [];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        networkRepositoryProvider.overrideWithValue(repo),
        shareTextProvider.overrideWithValue((text, _) async => shared.add(text)),
      ],
      child: MaterialApp(home: InviteScreen(initialQuery: q)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('nothing searched yet: intro and the plain share link', (tester) async {
    await pump(tester);
    expect(repo.lookups, isEmpty);
    expect(find.textContaining('Search the NPI Registry'), findsOneWidget);

    await tester.tap(find.text('Share invite link'));
    await tester.pump();
    expect(shared.single, startsWith("I'm on Doqto"));
    expect(shared.single, contains('https://doqto.ai/get'));
    expect(repo.invited, isEmpty);
  });

  testWidgets('each result shows the button for its status', (tester) async {
    await pump(tester, q: 'Patel');
    expect(repo.lookups, ['Patel/null']);
    expect(find.text('4 doctors in the NPI Registry'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Requested'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Invite'), findsOneWidget);
  });

  testWidgets('Invite remembers the NPI and shares a personal message', (tester) async {
    await pump(tester, q: 'Patel');
    await tester.tap(find.text('Invite'));
    await tester.pump();

    expect(repo.invited, ['1000000004']);
    expect(shared.single, startsWith("Dr. Patel, I'm on Doqto"));
  });

  testWidgets('typing searches again after the debounce', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'Neel Patel');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(repo.lookups, ['Neel Patel/null']);
  });
}
