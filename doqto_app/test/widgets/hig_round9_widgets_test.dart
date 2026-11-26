import 'dart:io';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/core/tokens/colors.dart';
import 'package:doqto_app/core/utils/async_retry.dart';
import 'package:doqto_app/core/utils/error_messages.dart';
import 'package:doqto_app/data/models/group.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/state/app_lock_state.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/settings_state.dart';
import 'package:doqto_app/ui/screens/media/image_crop_screen.dart';
import 'package:doqto_app/ui/widgets/app_lock_gate.dart';
import 'package:doqto_app/ui/widgets/attachment_bubbles.dart';
import 'package:doqto_app/ui/widgets/inline_banner.dart';
import 'package:doqto_app/ui/widgets/load_failed.dart';
import 'package:doqto_app/ui/widgets/mention_autocomplete.dart';
import 'package:doqto_app/ui/widgets/pinned_banner.dart';
import 'package:doqto_app/ui/widgets/reactions.dart';

/// HIG round 9: one test per fix that a widget test can pin.
Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

class _SignOutSpy extends AuthNotifier {
  int signOuts = 0;

  @override
  AuthState build() => const AuthState(AuthStage.signedOut, null);

  @override
  Future<void> signOut() async => signOuts++;
}

void main() {
  group('V1 mention suggestions', () {
    testWidgets('six two-line rows scroll inside a capped height', (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final members = [
        for (var i = 0; i < 9; i++)
          GroupMember(
            userId: 'u$i',
            fullName: 'Dr Person $i',
            specialty: 'Cardiology',
            headline: null,
            avatarColor: null,
            avatarUrl: null,
            role: GroupRole.member,
            state: GroupMemberState.active,
          ),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [MentionAutocomplete(members: members, query: '', meId: null, onPick: (_) {})],
          ),
        ),
      ));
      final list = tester.getSize(find.byKey(const ValueKey('mention-autocomplete-list')));
      expect(list.height, lessThanOrEqualTo(667 * 0.28 + 0.01));
      expect(tester.getSize(find.byKey(const ValueKey('mention-autocomplete'))).height, lessThan(240));
      // All six are there, the last one by scrolling.
      expect(find.byType(ListTile), findsNWidgets(6));
      await tester.ensureVisible(find.byKey(const ValueKey('mention-u5')));
      await tester.pump();
      GroupMember? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [MentionAutocomplete(members: members, query: '', meId: null, onPick: (m) => picked = m)],
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('mention-u5')));
      expect(picked?.userId, 'u5');
    });
  });

  group('V2 failed document bubble', () {
    testWidgets('with nothing to open, the tap reaches the handler around it', (tester) async {
      var outer = 0;
      await tester.pumpWidget(ProviderScope(
        child: _wrap(GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => outer++,
          child: FileBubble(
            getFileUrl: null,
            fileName: 'labs.pdf',
            fileSizeBytes: 2048,
            isMine: true,
            timestamp: DateTime(2026, 11, 8, 10),
            status: MessageStatus.failed,
          ),
        )),
      ));
      await tester.tap(find.text('labs.pdf'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(outer, 1, reason: 'Retry send / Delete message must be reachable');
    });
  });

  group('V3 crop corner targets', () {
    late File source;

    setUp(() {
      final picture = img.Image(width: 400, height: 300);
      img.fill(picture, color: img.ColorRgb8(40, 120, 130));
      source = File('${Directory.systemTemp.path}/crop_r9_${DateTime.now().microsecondsSinceEpoch}.png')
        ..writeAsBytesSync(img.encodePng(picture));
    });
    tearDown(() {
      if (source.existsSync()) source.deleteSync();
    });

    Future<void> open(WidgetTester tester, {bool circle = false}) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: ImageCropScreen(source: source, circle: circle)));
      // The file read and the package's image parse run off the test clock.
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        if (find.byKey(const ValueKey('crop-handle-topLeft')).evaluate().isNotEmpty) break;
      }
    }

    Rect handle(WidgetTester tester, String name) => tester.getRect(find.byKey(ValueKey('crop-handle-$name')));

    testWidgets('four 44x44 targets inside the canvas, each over its corner', (tester) async {
      await open(tester);
      final canvas = tester.getRect(find.byType(Crop));
      for (final name in ['topLeft', 'topRight', 'bottomLeft', 'bottomRight']) {
        final r = handle(tester, name);
        expect(r.size, const Size(44, 44), reason: name);
        expect(canvas.expandToInclude(r), canvas, reason: '$name is fully touchable');
      }
      expect(handle(tester, 'topLeft').left, lessThan(handle(tester, 'topRight').left));
      expect(handle(tester, 'topLeft').top, lessThan(handle(tester, 'bottomLeft').top));
    });

    testWidgets('dragging a target from its edge resizes the crop; free aspect moves one corner', (tester) async {
      await open(tester);
      final before = {
        for (final n in ['topLeft', 'topRight', 'bottomLeft', 'bottomRight']) n: handle(tester, n),
      };
      // Grab 3pt inside the target's inner corner: outside the package's
      // own 32pt handle wherever the target is centred on the corner.
      await tester.dragFrom(before['topLeft']!.bottomRight - const Offset(3, 3), const Offset(60, 70));
      await tester.pump();
      final after = handle(tester, 'topLeft');
      expect(after.left, greaterThan(before['topLeft']!.left + 20));
      expect(after.top, greaterThan(before['topLeft']!.top + 20));
      expect(handle(tester, 'bottomRight'), before['bottomRight'], reason: 'the opposite corner stays');
      expect(handle(tester, 'topRight').top, after.top);
      expect(handle(tester, 'bottomLeft').left, after.left);
    });

    testWidgets('the circle mask stays square while a corner is dragged', (tester) async {
      await open(tester, circle: true);
      await tester.dragFrom(handle(tester, 'topLeft').center, const Offset(50, 15));
      await tester.pump();
      final tl = handle(tester, 'topLeft').center;
      final br = handle(tester, 'bottomRight').center;
      final tr = handle(tester, 'topRight').center;
      // Targets not pushed in by an edge sit on the corners: equal sides.
      expect((tr.dx - tl.dx), closeTo(br.dy - tr.dy, 0.01));
    });
  });

  group('W1 retry shows progress', () {
    test('an errored value that is loading again draws the loading state', () {
      const failed = AsyncError<int>('boom', StackTrace.empty);
      String show(AsyncValue<int> v) =>
          v.whenRetrying(data: (d) => 'data', error: (e, _) => 'error', loading: () => 'loading');
      expect(show(failed), 'error');
      // What ref.invalidate leaves behind: the error, marked loading.
      final retrying = const AsyncLoading<int>().copyWithPrevious(failed);
      expect(retrying.hasError && retrying.isLoading, isTrue, reason: 'precondition');
      expect(
        retrying.when(data: (d) => 'data', error: (e, _) => 'error', loading: () => 'loading'),
        'error',
        reason: 'precondition: plain when keeps the error pane up',
      );
      expect(show(retrying), 'loading');
      expect(show(const AsyncData(1)), 'data');
      // A refresh over data keeps the data on screen.
      expect(show(const AsyncLoading<int>().copyWithPrevious(const AsyncData(1))), 'data');
    });

    testWidgets('LoadFailed(loading) disables Retry and keeps its name', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(LoadFailed(message: 'nope', onRetry: () => taps++, loading: true)));
      await tester.tap(find.byKey(const ValueKey('load-failed-retry')), warnIfMissed: false);
      expect(taps, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('W4 app lock', () {
    late FakeLocalAuthenticator auth;
    late _SignOutSpy spy;
    late ProviderContainer c;

    setUp(() {
      auth = FakeLocalAuthenticator(result: false);
      spy = _SignOutSpy();
      c = ProviderContainer(overrides: [
        localAuthenticatorProvider.overrideWithValue(auth),
        authProvider.overrideWith(() => spy),
      ]);
    });
    tearDown(() => c.dispose());

    Widget app() => UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            // Above the app's Navigator, as in main.dart.
            builder: (_, child) => AppLockGate(child: child!),
            home: const Scaffold(body: Text('secret chat')),
          ),
        );

    testWidgets('a failed unlock says why; no passcode on the phone says that', (tester) async {
      await c.read(appSettingsProvider.notifier).setAppLock(true);
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.pump();
      expect(find.text(Strings.appLockFailed), findsOneWidget);
      expect(c.read(appLockProvider).failure, AppLockFailure.notConfirmed);

      auth.available = false;
      await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
      await tester.pump();
      await tester.pump();
      expect(find.text(Strings.appLockUnavailable), findsOneWidget);
      expect(find.text(Strings.appLockFailed), findsNothing);
      // Announced: the reason lives in a live region.
      expect(_ancestorIsLive(tester), isTrue);
    });

    testWidgets('Sign out asks first, then signs out and lifts the lock', (tester) async {
      await c.read(appSettingsProvider.notifier).setAppLock(true);
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('app-lock-sign-out')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sign-out-cancel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sign-out-cancel')));
      await tester.pumpAndSettle();
      expect(spy.signOuts, 0);
      expect(find.byKey(const ValueKey('app-lock-screen')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('app-lock-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sign-out-confirm')));
      await tester.pumpAndSettle();
      expect(spy.signOuts, 1);
      expect(find.byKey(const ValueKey('app-lock-screen')), findsNothing);
      expect(c.read(appLockProvider).locked, isFalse);
    });
  });

  test('W5 the duplicate-NPI message names a control that exists', () {
    final text = ErrorMessages.forCode('npi_already_registered', fallback: '');
    expect(text, contains(Strings.regSignOut));
    expect(text, isNot(contains('previous screen')));
  });

  group('W7 pending media', () {
    testWidgets('an uploading photo and video have VoiceOver names', (tester) async {
      final handle = tester.ensureSemantics();
      // No file behind the path: the bubble draws its placeholder, which has
      // a size without waiting for a decode.
      final missing = '${Directory.systemTemp.path}/pending_r9_missing.png';
      await tester.pumpWidget(_wrap(Column(mainAxisSize: MainAxisSize.min, children: [
        PendingImageBubble(path: missing, isMine: true, timestamp: DateTime(2026, 11, 8, 10), status: MessageStatus.failed),
        PendingVideoBubble(posterPath: null, durationSec: 65, isMine: true, timestamp: DateTime(2026, 11, 8, 10), status: MessageStatus.failed),
      ])));
      // The failed file read lands off the test clock.
      for (var i = 0; i < 20 && find.byIcon(Icons.broken_image_outlined).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(find.semantics.byLabel(Strings.mediaPhoto), findsOneWidget);
      expect(find.semantics.byLabel('${Strings.mediaVideo}, 1:05'), findsOneWidget);
      handle.dispose();
    });
  });

  group('W12 pinned banner', () {
    testWidgets('the strip is one button; Unpin is its own', (tester) async {
      final handle = tester.ensureSemantics();
      var jumps = 0, unpins = 0;
      await tester.pumpWidget(_wrap(PinnedBanner(
        message: null,
        senderName: 'Dr Kim',
        onTap: () => jumps++,
        onUnpin: () => unpins++,
      )));
      final strip = find.semantics.byLabel('${Strings.chatPinnedMessage} · Dr Kim, ${Strings.chatPinnedMessage}');
      expect(strip, findsOneWidget);
      final data = strip.evaluate().single.getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(find.byTooltip(Strings.chatUnpinMessage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pinned-banner-text')));
      await tester.tap(find.byKey(const ValueKey('pinned-banner-unpin')));
      expect((jumps, unpins), (1, 1));
      handle.dispose();
    });
  });

  group('W13 my reaction', () {
    Widget pills(String? me) => _wrap(ReactionPills(
          reactions: const [
            MessageReaction(emoji: '👍', userIds: ['a', 'me']),
          ],
          me: me,
          onTap: () {},
        ));

    BoxDecoration fill(WidgetTester tester) => tester
        .widgetList<Container>(find.descendant(of: find.byKey(const ValueKey('reaction-pills')), matching: find.byType(Container)))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .first;

    testWidgets('is filled and spoken, not only outlined', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(pills('me'));
      expect(fill(tester).color, AppColors.medBlueLight);
      expect(tester.widget<Text>(find.byKey(const ValueKey('reaction-total'))).style?.color, AppColors.medBlueDark);
      expect(find.semantics.byPredicate((n) => n.label.contains(Strings.reactionIncludingYours)), findsOneWidget);

      await tester.pumpWidget(pills('someone-else'));
      expect(fill(tester).color, AppColors.white);
      expect(find.semantics.byPredicate((n) => n.label.contains(Strings.reactionIncludingYours)), findsNothing);
      handle.dispose();
    });
  });

  group('W16 inline banner', () {
    testWidgets('two lines by default, more when asked', (tester) async {
      await tester.pumpWidget(_wrap(const InlineBanner(tone: BannerTone.warn, text: 'a')));
      expect(tester.widget<Text>(find.text('a')).maxLines, 2);
      await tester.pumpWidget(_wrap(const InlineBanner(tone: BannerTone.warn, text: 'a', maxLines: 4)));
      expect(tester.widget<Text>(find.text('a')).maxLines, 4);
    });
  });
}

bool _ancestorIsLive(WidgetTester tester) {
  final live = find.ancestor(
    of: find.byKey(const ValueKey('app-lock-failure')),
    matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.liveRegion == true),
  );
  return live.evaluate().isNotEmpty;
}
