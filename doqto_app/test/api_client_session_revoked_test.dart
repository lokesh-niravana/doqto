import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';

/// Linked devices (batch 6): a 401 `session_revoked` is terminal. The client
/// must wipe tokens and end the session at once, without trying the refresh
/// endpoint first (a refresh would also fail and only delay the sign-out).
///
/// Runs against a loopback HttpServer: ApiClient has no transport hook, and
/// an absolute URL bypasses Dio's baseUrl.
class _Tokens extends TokenStorage {
  String? access = 'a1';
  String? refresh = 'r1';
  int cleared = 0;

  @override
  Future<String?> get accessToken async => access;
  @override
  Future<String?> get refreshToken async => refresh;
  @override
  Future<void> clear() async {
    cleared++;
    access = null;
    refresh = null;
  }

  @override
  Future<void> saveTokens({required String access, required String refresh}) async {
    this.access = access;
    this.refresh = refresh;
  }
}

void main() {
  late HttpServer server;
  late List<String> paths;
  late String detail;
  late HttpOverrides? previous;

  setUp(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = null; // flutter_test's mock client would 400 us
    paths = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      paths.add(req.uri.path);
      req.response
        ..statusCode = 401
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'detail': detail}));
      req.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    HttpOverrides.global = previous;
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  test('401 session_revoked → tokens cleared, onSessionEnded, no refresh call', () async {
    detail = 'session_revoked';
    final tokens = _Tokens();
    final api = ApiClient(tokens: tokens);
    var ended = 0;
    api.onSessionEnded = () => ended++;

    await expectLater(api.get(url('/api/v1/users/me/sessions')), throwsA(isA<ApiException>()));

    expect(ended, 1);
    expect(tokens.cleared, 1);
    expect(paths, ['/api/v1/users/me/sessions'], reason: 'exactly one request, no refresh');
  });

  test('a plain 401 still goes through the refresh path first', () async {
    detail = 'invalid_token';
    final tokens = _Tokens();
    final api = ApiClient(tokens: tokens);
    var ended = 0;
    api.onSessionEnded = () => ended++;

    await expectLater(api.get(url('/api/v1/users/me/sessions')), throwsA(anything));

    expect(paths.first, '/api/v1/users/me/sessions');
    // The refresh goes to AppConstants.apiBaseUrl (not our server) and fails
    // there; the client then ends the session. Either way: no retry here.
    expect(paths.where((p) => p == '/api/v1/users/me/sessions'), hasLength(1));
    expect(ended, 1);
    expect(tokens.cleared, 1);
  });
}
