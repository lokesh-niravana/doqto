import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/ui/screens/voice_broadcast/voice_broadcast_screen.dart';

// A doctor's recipients are their connections and groups, org or no org.

PersonCard _person(String id, String name) => PersonCard(
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

Conversation _group(String id, String name) {
  final now = DateTime(2026).toIso8601String();
  return Conversation.fromJson({
    'id': id,
    'type': ConversationType.group.wire,
    'name': name,
    'member_ids': ['me', 'them'],
    'created_at': now,
    'updated_at': now,
  });
}

class _Convs extends ConversationsNotifier {
  _Convs(this.list);
  final List<Conversation> list;
  @override
  Future<List<Conversation>> build() async => list;
}

Widget _app(List<PersonCard> people, [List<Conversation> convs = const []]) =>
    ProviderScope(
      overrides: [
        invitablePeopleProvider.overrideWith((ref) async => people),
        conversationsProvider.overrideWith(() => _Convs(convs)),
      ],
      child: const MaterialApp(home: VoiceBroadcastScreen()),
    );

void main() {
  testWidgets('a connection is selectable with no organization', (t) async {
    await t.pumpWidget(_app([_person('u1', 'Dr. Nanavati H')]));
    await t.pumpAndSettle();

    expect(find.text('PEOPLE'), findsOneWidget);
    await t.tap(find.text('Dr. Nanavati H'));
    await t.pump();
    expect(find.text('Next (1)'), findsWidgets);
  });

  testWidgets('groups are listed alongside people', (t) async {
    await t.pumpWidget(
      _app(
        [_person('u1', 'Dr. Nanavati H')],
        [_group('g1', 'Cardiology Team')],
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('GROUPS'), findsOneWidget);
    expect(find.text('Cardiology Team'), findsOneWidget);
  });

  testWidgets('nobody to send to explains itself', (t) async {
    await t.pumpWidget(_app(const []));
    await t.pumpAndSettle();
    expect(find.text('No one to send to yet'), findsOneWidget);
    expect(find.text('Find doctors on Doqto'), findsWidgets);
    expect(find.text('PEOPLE'), findsNothing);
  });
}
