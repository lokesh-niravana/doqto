import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/services/chat_media_cache.dart';
import 'package:doqto_app/state/auth_state.dart';

import 'support/fake_media_backend.dart';

// Remote wipe (batch 6/7): a 401 `session_revoked` or `account_deleted` ends
// the session on the spot — no refresh attempt — and the app wipes its PHI
// and drops to login.

class _Tokens extends TokenStorage {
  String? access = 'a.b.c';
  String? refresh = 'r';
  int clears = 0;
  @override
  Future<String?> get accessToken async => access;
  @override
  Future<String?> get refreshToken async => refresh;
  @override
  Future<void> clear() async {
    clears++;
    access = null;
    refresh = null;
  }

  @override
  Future<void> saveTokens({required String access, required String refresh}) async {
    this.access = access;
    this.refresh = refresh;
  }
}

// No TestWidgetsFlutterBinding here on purpose: it stubs every HttpClient
// with a 400 answer, and this test talks to a real loopback server.
void main() {

  late HttpServer server;
  final hits = <String>[];
  String detail = 'session_revoked';

  setUp(() async {
    hits.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      hits.add('${req.method} ${req.uri.path}');
      req.response
        ..statusCode = 401
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'detail': detail}));
      req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  String base() => 'http://${server.address.host}:${server.port}';

  test('401 session_revoked ends the session without trying to refresh', () async {
    final tokens = _Tokens();
    final api = ApiClient(tokens: tokens, baseUrl: base());
    var ended = 0;
    api.onSessionEnded = () => ended++;

    await expectLater(api.get('/api/v1/users/me'), throwsA(isA<ApiException>()));

    expect(ended, 1);
    expect(tokens.clears, 1);
    expect(hits, ['GET /api/v1/users/me'], reason: 'no POST /auth/refresh');
  });

  test('401 account_deleted does the same', () async {
    detail = 'account_deleted';
    final tokens = _Tokens();
    final api = ApiClient(tokens: tokens, baseUrl: base());
    var ended = 0;
    api.onSessionEnded = () => ended++;
    await expectLater(api.get('/api/v1/users/me'), throwsA(isA<ApiException>()));
    expect(ended, 1);
    expect(hits, hasLength(1));
    detail = 'session_revoked';
  });

  test('an ordinary 401 still goes through the refresh path first', () async {
    detail = 'invalid_token';
    final tokens = _Tokens();
    final api = ApiClient(tokens: tokens, baseUrl: base());
    var ended = 0;
    api.onSessionEnded = () => ended++;
    await expectLater(api.get('/api/v1/users/me'), throwsA(isA<ApiException>()));
    expect(hits, ['GET /api/v1/users/me', 'POST /api/v1/auth/refresh']);
    expect(ended, 1, reason: 'the refresh was refused too');
    detail = 'session_revoked';
  });

  test('the ended session wipes cached photos and returns to login', () async {
    final tokens = _Tokens();
    final api = ApiClient(tokens: tokens, baseUrl: base());
    final backend = FakeMediaBackend();
    final cache = ChatMediaCache(backend);
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      chatMediaCacheProvider.overrideWithValue(cache),
    ]);
    addTearDown(c.dispose);
    c.read(authProvider); // installs onSessionEnded
    final photo = await cache.image('m1', () async => 'https://s3.example/m1');
    expect(photo.existsSync(), isTrue);

    await expectLater(api.get('/api/v1/users/me'), throwsA(isA<ApiException>()));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(c.read(authProvider).stage, AuthStage.signedOut);
    expect(backend.clears, 1);
    expect(photo.existsSync(), isFalse);
  });
}
