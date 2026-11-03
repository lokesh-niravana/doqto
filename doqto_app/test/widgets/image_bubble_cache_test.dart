import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/services/chat_media_cache.dart';
import 'package:doqto_app/ui/widgets/attachment_bubbles.dart';

import '../support/fake_media_backend.dart';

// Leaving a chat and coming back remounts every bubble. Before the fix each
// remount resolved a new presigned URL and downloaded the photo again.

void main() {
  late FakeMediaBackend backend;
  late ChatMediaCache cache;
  late int urlCalls;

  setUp(() {
    backend = FakeMediaBackend();
    cache = ChatMediaCache(backend);
    urlCalls = 0;
  });

  Widget thread({required bool open}) => ProviderScope(
        overrides: [chatMediaCacheProvider.overrideWithValue(cache)],
        child: MaterialApp(
          home: Scaffold(
            body: open
                ? ImageBubble(
                    key: const ValueKey('m1'),
                    messageId: 'm1',
                    getFileUrl: () async =>
                        'https://s3.example/m1?sig=${++urlCalls}',
                    isMine: false,
                    timestamp: DateTime(2026, 11, 3, 9),
                  )
                : const SizedBox(),
          ),
        ),
      );

  // The fake backend does synchronous file IO, so the cache's futures resolve
  // as microtasks: a couple of pumps settle them without leaving the fake
  // clock (real async would also let google_fonts hit the network).
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a photo downloads once and survives leaving the chat',
      (tester) async {
    await tester.pumpWidget(thread(open: true));
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: 'first view: nothing on the phone yet');
    await settle(tester);
    expect(find.byType(Image), findsOneWidget);

    for (var visit = 0; visit < 3; visit++) {
      await tester.pumpWidget(thread(open: false)); // back out
      await tester.pumpWidget(thread(open: true)); // come back in
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'cached photo paints on the first frame');
      expect(find.byType(Image), findsOneWidget);
    }

    expect(urlCalls, 1);
    expect(backend.downloadedUrls, hasLength(1));
  });

  testWidgets('a failed load shows a retry that fetches again',
      (tester) async {
    var fail = true;
    await tester.pumpWidget(ProviderScope(
      overrides: [chatMediaCacheProvider.overrideWithValue(cache)],
      child: MaterialApp(
        home: Scaffold(
          body: ImageBubble(
            messageId: 'm2',
            getFileUrl: () async {
              urlCalls++;
              if (fail) throw Exception('offline');
              return 'https://s3.example/m2';
            },
            isMine: true,
            timestamp: DateTime(2026, 11, 3, 9),
          ),
        ),
      ),
    ));
    await settle(tester);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);

    fail = false;
    await tester.tap(find.byIcon(Icons.broken_image_outlined));
    await settle(tester);

    expect(find.byType(Image), findsOneWidget);
    expect(urlCalls, 2);
  });
}
