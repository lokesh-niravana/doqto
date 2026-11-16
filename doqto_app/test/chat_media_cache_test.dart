import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/data/services/chat_media_cache.dart';

import 'support/fake_media_backend.dart';

// The bug: every visit to a chat re-downloaded every photo, because the cache
// was keyed by a presigned URL that changes on every request. These tests pin
// the fix: keyed by message id, a URL is resolved only on a true miss.

void main() {
  late FakeMediaBackend backend;
  late ChatMediaCache cache;
  late int urlCalls;

  Future<String> resolve() async => 'https://s3.example/img?sig=${++urlCalls}';

  setUp(() {
    backend = FakeMediaBackend();
    cache = ChatMediaCache(backend);
    urlCalls = 0;
  });

  test('the first view downloads; every later view reads the phone',
      () async {
    final first = await cache.image('m1', resolve);
    final again = await cache.image('m1', resolve);

    expect(urlCalls, 1);
    expect(backend.downloadedUrls, hasLength(1));
    expect(again.path, first.path);
    expect(cache.peek('m1')?.path, first.path,
        reason: 'a remounted bubble paints synchronously');
  });

  test('after an app restart the photo still comes from the phone', () async {
    await cache.image('m1', resolve);
    final restarted = ChatMediaCache(backend); // in-memory map gone

    expect(restarted.peek('m1'), isNull);
    await restarted.image('m1', resolve);

    expect(urlCalls, 1, reason: 'no new URL, no new download');
    expect(backend.downloadedUrls, hasLength(1));
  });

  test('bubble and viewer asking at once share one download', () async {
    final results = await Future.wait([
      cache.image('m1', resolve),
      cache.image('m1', resolve),
      cache.image('m1', resolve),
    ]);

    expect(urlCalls, 1);
    expect(backend.downloadedUrls, hasLength(1));
    expect(results.map((f) => f.path).toSet(), hasLength(1));
  });

  test('the sender never downloads their own photo', () async {
    final local = File('${backend.dir.path}/outbox.jpg')
      ..writeAsBytesSync(FakeMediaBackend.png);

    await cache.seed('m1', local);
    local.deleteSync(); // the outbox deletes its copy right after sending
    final f = await cache.image('m1', resolve);

    expect(urlCalls, 0);
    expect(f.readAsBytesSync(), FakeMediaBackend.png);
  });

  test('a deleted message leaves nothing on the phone', () async {
    final f = await cache.image('m1', resolve);
    await cache.evict('m1');

    expect(f.existsSync(), isFalse);
    expect(cache.peek('m1'), isNull);
  });

  test('sign-out clears every cached photo', () async {
    final a = await cache.image('m1', resolve);
    final b = await cache.image('m2', resolve);
    await cache.clear();

    expect(backend.clears, 1);
    expect(a.existsSync() || b.existsSync(), isFalse);
    expect(cache.peek('m1'), isNull);
    expect(cache.peek('m2'), isNull);
  });

  test('a failed fetch is not remembered: the next view retries', () async {
    var fail = true;
    Future<String> flaky() async {
      urlCalls++;
      if (fail) throw const SocketException('offline');
      return 'https://s3.example/img';
    }

    await expectLater(cache.image('m1', flaky), throwsA(isA<SocketException>()));
    fail = false;
    await cache.image('m1', flaky);

    expect(urlCalls, 2);
    expect(backend.downloadedUrls, hasLength(1));
  });

  test('a file the OS purged is downloaded again, once', () async {
    final f = await cache.image('m1', resolve);
    f.deleteSync(); // iOS may purge Caches under storage pressure

    expect(cache.peek('m1'), isNull);
    await cache.image('m1', resolve);
    await cache.image('m1', resolve);

    expect(backend.downloadedUrls, hasLength(2));
  });
}
