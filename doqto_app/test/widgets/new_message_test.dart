import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/state/org_state.dart';
import 'package:doqto_app/ui/screens/chat/new_message_screen.dart';

// "Start a conversation" opens a contact picker: tap a person, land in the chat.

PersonCard _conn(String id, String name) => PersonCard(
      id: id,
      fullName: name,
      headline: null,
      specialty: 'Cardiology',
      locationLabel: null,
      avatarColor: null,
      avatarUrl: null,
      avatarPresignedUrl: null,
      degree: ConnectionDegree.first,
      mutualCount: 0,
    );

OrgMember _member(String id, String name) => OrgMember(
      id: id,
      fullName: name,
      specialty: 'Neurology',
      orgRole: OrgRole.doctor,
      joinedAt: DateTime(2026),
      presence: PresenceStatus.offline,
      avatarColor: null,
      avatarUrl: null,
      avatarPresignedUrl: null,
    );

Organization _org(OrgStatus status) => Organization(
      id: 'org-1',
      name: 'Saint Lukes',
      address: null,
      city: null,
      state: null,
      practiceType: null,
      inviteCode: 'X',
      status: status,
      reviewNotes: null,
      verifiedAt: null,
      createdAt: DateTime(2026),
      memberCount: 2,
    );

class _Conns extends ConnectionsNotifier {
  _Conns(this.people);
  final List<PersonCard> people;
  @override
  Future<List<PersonCard>> build() async => people;
}

class _Org extends OrgNotifier {
  _Org(this.org);
  final Organization? org;
  @override
  OrgState build() => OrgState(current: org);
}

class _Chats extends ChatRepository {
  _Chats() : super(ApiClient());
  final opened = <String>[];
  @override
  Future<Conversation> createConversation({
    required ConversationType type,
    String? name,
    required List<String> memberIds,
  }) async {
    opened.add(memberIds.single);
    final now = DateTime(2026).toIso8601String();
    return Conversation.fromJson({
      'id': 'conv-${memberIds.single}',
      'type': 'direct',
      'member_ids': [memberIds.single],
      'created_at': now,
      'updated_at': now,
    });
  }
}

late _Chats _chats;

Future<void> _open(
  WidgetTester tester, {
  List<PersonCard> connections = const [],
  Organization? org,
  List<OrgMember> members = const [],
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  _chats = _Chats();
  final router = GoRouter(
    initialLocation: '/chats',
    routes: [
      GoRoute(
        path: '/chats',
        builder: (c, _) => TextButton(
          onPressed: () => c.push(AppRoutes.newMessage),
          child: const Text('CHATS'),
        ),
      ),
      GoRoute(path: AppRoutes.newMessage, builder: (_, _) => const NewMessageScreen()),
      GoRoute(
        path: '/chat/:id',
        builder: (_, s) => Text('THREAD ${s.pathParameters['id']}'),
      ),
      GoRoute(path: AppRoutes.groupsCreate, builder: (_, _) => const Text('NEW GROUP')),
      GoRoute(path: AppRoutes.peopleSearch, builder: (_, _) => const Text('SEARCH')),
      GoRoute(path: AppRoutes.myOrg, builder: (_, _) => const Text('MY ORG')),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      connectionsProvider.overrideWith(() => _Conns(connections)),
      orgProvider.overrideWith(() => _Org(org)),
      orgMembersProvider.overrideWith((ref, id) async => members),
      chatRepositoryProvider.overrideWithValue(_chats),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('CHATS'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a doctor with no org sees connections and opens a chat',
      (tester) async {
    await _open(tester, connections: [_conn('u1', 'Dr Anita Kumar')]);

    expect(find.text('CONNECTIONS'), findsOneWidget);
    expect(find.text('New group'), findsNothing);
    expect(find.text('Want group chats with your team?'), findsOneWidget);

    await tester.tap(find.text('Dr Anita Kumar'));
    await tester.pumpAndSettle();
    expect(_chats.opened, ['u1']);
    expect(find.text('THREAD conv-u1'), findsOneWidget);

    // The picker was replaced: back goes to Chats, not to the picker.
    final r = GoRouter.of(tester.element(find.text('THREAD conv-u1')));
    r.pop();
    await tester.pumpAndSettle();
    expect(find.text('CHATS'), findsOneWidget);
  });

  testWidgets('in a verified org: new group, colleagues, one row per person',
      (tester) async {
    await _open(
      tester,
      connections: [_conn('u1', 'Dr Anita Kumar')],
      org: _org(OrgStatus.active),
      members: [_member('u1', 'Dr Anita Kumar'), _member('u2', 'Dr Raj Shah')],
    );

    expect(find.text('New group'), findsOneWidget);
    expect(find.text('COLLEAGUES · SAINT LUKES'), findsOneWidget);
    expect(find.text('Dr Anita Kumar'), findsOneWidget);
    expect(find.text('Dr Raj Shah'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'raj');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Dr Anita Kumar'), findsNothing);
    expect(find.text('Dr Raj Shah'), findsOneWidget);
    expect(find.text('New group'), findsNothing);
  });

  testWidgets('a pending org hides new group', (tester) async {
    await _open(
      tester,
      connections: [_conn('u1', 'Dr Anita Kumar')],
      org: _org(OrgStatus.pending),
    );
    expect(find.text('New group'), findsNothing);
  });

  testWidgets('nobody to message points to finding doctors', (tester) async {
    await _open(tester);
    expect(find.text('No one to message yet'), findsOneWidget);
    await tester.tap(find.text('Find doctors on Doqto').last);
    await tester.pumpAndSettle();
    expect(find.text('SEARCH'), findsOneWidget);
  });
}
