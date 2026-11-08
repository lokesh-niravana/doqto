import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/repositories/network_repository.dart';
import 'package:doqto_app/ui/screens/people/person_profile_screen.dart';
import 'package:doqto_app/ui/screens/settings/blocked_list_screen.dart';

import '../support/fake_socket.dart';

PersonCard _card(String id, String name) => PersonCard.fromJson({
      'id': id,
      'full_name': name,
      'degree': 'out',
    });

class _Repo extends NetworkRepository {
  _Repo() : super(ApiClient());
  var blocks = <PersonCard>[_card('u1', 'Dr One'), _card('u2', 'Dr Two')];
  final unblocked = <String>[];
  bool fail = false;
  String profileState = 'blocked';

  @override
  Future<CursorPage<PersonCard>> listBlocks({String? cursor}) async =>
      CursorPage(List.of(blocks), null);

  @override
  Future<void> unblock(String userId) async {
    if (fail) throw ApiException('boom', status: 500);
    unblocked.add(userId);
    blocks = [for (final b in blocks) if (b.id != userId) b];
  }

  @override
  Future<NetworkProfile> getProfile(String userId) async =>
      NetworkProfile.fromJson({
        'id': userId,
        'full_name': 'Dr One',
        'degree': 'out',
        'connection_state': profileState,
        'can_message': 'denied',
      });
}

late _Repo _repo;

Widget app(Widget home) => ProviderScope(
      overrides: [
        networkRepositoryProvider.overrideWithValue(_repo),
        websocketClientProvider.overrideWithValue(FakeSocket()),
      ],
      child: MaterialApp(home: home),
    );

void main() {
  setUp(() => _repo = _Repo());

  testWidgets('lists blocked doctors and unblocks after confirming',
      (tester) async {
    await tester.pumpWidget(app(const BlockedListScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Dr One'), findsOneWidget);
    expect(find.text('Dr Two'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('unblock-u1')));
    await tester.pumpAndSettle();
    expect(find.text(Strings.privacyUnblockConfirmTitle), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, Strings.cancel));
    await tester.pumpAndSettle();
    expect(_repo.unblocked, isEmpty, reason: 'cancel never calls the API');

    await tester.tap(find.byKey(const ValueKey('unblock-u1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('unblock-confirm')));
    await tester.pump(); // optimistic: row gone before the _repo answers
    expect(find.text('Dr One'), findsNothing);
    await tester.pumpAndSettle();
    expect(_repo.unblocked, ['u1']);
    expect(find.text(Strings.privacyUnblockedToast), findsOneWidget);
  });

  testWidgets('a refused unblock brings the row back', (tester) async {
    _repo.fail = true;
    await tester.pumpWidget(app(const BlockedListScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('unblock-u2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('unblock-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Dr Two'), findsOneWidget);
  });

  testWidgets('empty state when nobody is blocked', (tester) async {
    _repo.blocks = [];
    await tester.pumpWidget(app(const BlockedListScreen()));
    await tester.pumpAndSettle();
    expect(find.text(Strings.privacyBlockedEmpty), findsOneWidget);
  });

  testWidgets('a blocked profile offers Unblock instead of Connect',
      (tester) async {
    await tester.pumpWidget(app(const PersonProfileScreen(userId: 'u1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-blocked-banner')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-unblock-button')), findsOneWidget);
    expect(find.text(Strings.netConnect), findsNothing);
    expect(find.text(Strings.netMessage), findsNothing);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-unblock')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-block')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('profile-unblock')));
    await tester.pumpAndSettle();
    _repo.profileState = 'none';
    await tester.tap(find.byKey(const ValueKey('unblock-confirm')));
    await tester.pumpAndSettle();
    expect(_repo.unblocked, ['u1']);
    expect(find.byKey(const ValueKey('profile-unblock-button')), findsNothing);
  });
}
