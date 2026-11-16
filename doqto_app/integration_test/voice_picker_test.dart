// On-device check for the Send voice note picker: connections and groups show
// with no organization, and an empty network explains itself.
//
//   flutter test integration_test/voice_picker_test.dart -d <simulator> \
//     [--dart-define=SHOT_DIR=<folder on this Mac>]
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/ui/screens/voice_broadcast/voice_broadcast_screen.dart';

const _shotDir = String.fromEnvironment('SHOT_DIR');

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/shot_$name.png')
      .writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t) async {
  final end = DateTime.now().add(const Duration(milliseconds: 1200));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

PersonCard _person(String id, String name, String specialty) => PersonCard(
      id: id,
      fullName: name,
      headline: null,
      specialty: specialty,
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

Widget _app(Key key, List<PersonCard> people, List<Conversation> convs) =>
    ProviderScope(
      key: key,
      overrides: [
        invitablePeopleProvider.overrideWith((ref) async => people),
        conversationsProvider.overrideWith(() => _Convs(convs)),
      ],
      child: const MaterialApp(home: VoiceBroadcastScreen()),
    );

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('picker lists people and groups, or explains', (t) async {
    await t.pumpWidget(_app(
      const ValueKey('full'),
      [
        _person('u1', 'Dr. Nanavati H', 'Cardiology'),
        _person('u2', 'Dr. Ben Osei', 'Neurology'),
      ],
      [_group('g1', 'Cardiology Team')],
    ));
    await _settle(t);
    expect(find.text('GROUPS'), findsOneWidget);
    expect(find.text('PEOPLE'), findsOneWidget);
    await t.tap(find.text('Dr. Nanavati H'));
    await _settle(t);
    expect(find.text('Next (1)'), findsWidgets);
    await _shot(t, 'picker_full');

    await t.pumpWidget(_app(const ValueKey('empty'), const [], const []));
    await _settle(t);
    expect(find.text('No one to send to yet'), findsOneWidget);
    await _shot(t, 'picker_empty');
  });
}
