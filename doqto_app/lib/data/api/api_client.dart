import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../core/constants/api_routes.dart';
import '../../core/constants/app_constants.dart';
import '../../core/security/certificate_pinning.dart';
import '../services/network_usage.dart';
import 'token_storage.dart';

class ApiException implements Exception {
  final int? status;
  final String detail;
  ApiException(this.detail, {this.status});

  @override
  String toString() => 'ApiException($status): $detail';
}

/// `exp` claim of a JWT as a UTC instant, or null when the token is not a
/// readable JWT. No signature check — this is only for deciding whether to
/// refresh before the server would reject it.
DateTime? jwtExpiry(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final exp = (jsonDecode(payload) as Map<String, dynamic>)['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true);
  } catch (_) {
    return null;
  }
}

/// Called by the interceptor when the refresh attempt itself is unrecoverable
/// (refresh token expired/revoked). Set by the DI layer so the client can
/// signal auth state to flip to signedOut without a circular import.
typedef SessionEndedCallback = void Function();

/// 401 codes that mean this device's session is gone for good: no refresh
/// could revive it, so the app wipes its PHI and returns to login at once
/// (docs/security.md, "Sessions and devices").
const Set<String> sessionTerminalCodes = {'session_revoked', 'account_deleted'};

class ApiClient {
  final Dio _dio;
  final TokenStorage _tokens;
  final String _baseUrl;

  // One-at-a-time refresh. Future completes when the in-flight refresh
  // finishes; null means no refresh is running. Must be reassigned on every
  // attempt — a single Completer cannot be reused.
  Future<void>? _refreshInFlight;

  SessionEndedCallback? onSessionEnded;

  /// Bytes up / down for Storage and data (batch 5). Null = not counted.
  final NetworkUsage? usage;

  /// [baseUrl] defaults to the build's API; tests point it at a local server.
  ApiClient({TokenStorage? tokens, this.usage, String? baseUrl})
      : _tokens = tokens ?? TokenStorage(),
        _baseUrl = baseUrl ?? AppConstants.apiBaseUrl,
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? AppConstants.apiBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          contentType: 'application/json',
        )) {
    _dio.httpClientAdapter = _pinnedAdapter(_baseUrl);
    _dio.interceptors.add(InterceptorsWrapper(
      onResponse: (resp, handler) {
        _count(resp.requestOptions, resp);
        handler.next(resp);
      },
      onRequest: (opts, handler) async {
        // Never attach a token to auth endpoints — they either don't need one
        // (otp, refresh) or receive it via a dedicated Header param (logout).
        if (!_isAuthEndpoint(opts.path)) {
          final token = await _tokens.accessToken;
          if (token != null && token.isNotEmpty) {
            opts.headers['Authorization'] = 'Bearer $token';
          }
        }
        handler.next(opts);
      },
      onError: (e, handler) async {
        final is401 = e.response?.statusCode == 401;
        final alreadyRetried = e.requestOptions.extra['retried'] == true;
        final isRefreshCall = e.requestOptions.path.contains(ApiRoutes.authRefresh);
        if (!is401 || alreadyRetried || isRefreshCall) {
          return handler.next(e);
        }
        if (sessionTerminalCodes.contains(_detailOf(e))) {
          // Remote wipe: the session was revoked from another device or the
          // account is gone. Do not try to refresh — end the session now.
          await _tokens.clear();
          onSessionEnded?.call();
          return handler.next(e);
        }
        try {
          await _refreshOnce();
        } catch (_) {
          // Refresh failed — wipe tokens and let the app flip to signedOut.
          await _tokens.clear();
          onSessionEnded?.call();
          return handler.next(e);
        }
        try {
          final opts = e.requestOptions;
          opts.extra['retried'] = true;
          final newToken = await _tokens.accessToken;
          if (newToken != null && newToken.isNotEmpty) {
            opts.headers['Authorization'] = 'Bearer $newToken';
          }
          final resp = await _dio.fetch(opts);
          return handler.resolve(resp);
        } catch (retryErr) {
          if (retryErr is DioException) return handler.next(retryErr);
          return handler.next(e);
        }
      },
    ));
  }

  /// Transport with the production trust store pinned in release
  /// (`CertificatePinning`); the post-handshake leaf check runs on every
  /// response from the pinned host.
  static HttpClientAdapter _pinnedAdapter(String baseUrl) => IOHttpClientAdapter(
        createHttpClient: () => CertificatePinning.httpClient(baseUrl),
        validateCertificate: CertificatePinning.validateLeaf,
      );

  static String? _detailOf(DioException e) {
    final data = e.response?.data;
    return data is Map ? data['detail']?.toString() : null;
  }

  /// Network usage: the request body as sent and the response body as
  /// received. Multipart bodies report their length; streamed bodies are
  /// counted by the caller.
  void _count(RequestOptions req, Response<dynamic>? resp) {
    final u = usage;
    if (u == null) return;
    u.addSent(_sizeOf(req.data));
    final header = resp?.headers.value(Headers.contentLengthHeader);
    final parsed = header == null ? null : int.tryParse(header);
    u.addReceived(parsed ?? _sizeOf(resp?.data));
  }

  static int _sizeOf(Object? data) {
    if (data == null) return 0;
    if (data is List<int>) return data.length;
    if (data is String) return utf8.encode(data).length;
    if (data is FormData) return data.length;
    if (data is Map || data is List) return utf8.encode(jsonEncode(data)).length;
    return 0;
  }

  /// Access token that will still be valid in a minute, refreshing first if
  /// needed. The socket dials with this: a token that expired while the app
  /// was backgrounded would otherwise bounce off the server (4401) until some
  /// REST call happened to trigger the interceptor's refresh. A refresh the
  /// server rejects ends the session exactly like the interceptor does; a
  /// network failure returns the token we have and lets the caller retry.
  Future<String?> freshAccessToken() async {
    final token = await _tokens.accessToken;
    if (token == null || token.isEmpty) return null;
    final exp = jwtExpiry(token);
    if (exp == null ||
        exp.isAfter(DateTime.now().toUtc().add(tokenRefreshLeeway))) {
      return token;
    }
    try {
      await _refreshOnce();
    } on ApiException catch (e) {
      if (e.status == 401 || e.status == 403) {
        await _tokens.clear();
        onSessionEnded?.call();
        return null;
      }
      return token;
    } catch (_) {
      return token;
    }
    return _tokens.accessToken;
  }

  /// Refresh when the access token expires within this window.
  static const Duration tokenRefreshLeeway = Duration(seconds: 60);

  bool _isAuthEndpoint(String path) =>
      path.contains(ApiRoutes.authFirebase) ||
      path.contains(ApiRoutes.authRefresh);

  /// Ensures at most one refresh round-trip is in flight. Concurrent 401s
  /// all await the same Future; each attempt uses a fresh Future so the
  /// client doesn't deadlock after the first refresh resolves.
  Future<void> _refreshOnce() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final fut = _doRefresh().whenComplete(() => _refreshInFlight = null);
    _refreshInFlight = fut;
    return fut;
  }

  Future<void> _doRefresh() async {
    final refresh = await _tokens.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw ApiException('no_refresh_token', status: 401);
    }
    // Bare Dio — no interceptor, no recursion. Same pinned transport.
    final bare = Dio(BaseOptions(baseUrl: _baseUrl))
      ..httpClientAdapter = _pinnedAdapter(_baseUrl);
    try {
      final resp = await bare.post(
        ApiRoutes.authRefresh,
        data: {'refresh_token': refresh},
      );
      await _tokens.saveTokens(
        access: resp.data['access_token'] as String,
        refresh: resp.data['refresh_token'] as String,
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final detail = (e.response?.data is Map)
          ? (e.response!.data['detail']?.toString() ?? 'refresh_failed')
          : 'refresh_failed';
      throw ApiException(detail, status: status);
    }
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async {
    final r = await _call(() => _dio.get(path, queryParameters: query));
    return (r.data as Map).cast<String, dynamic>();
  }

  Future<List<dynamic>> getList(String path, {Map<String, dynamic>? query}) async {
    final r = await _call(() => _dio.get(path, queryParameters: query));
    return (r.data as List).cast<dynamic>();
  }

  Future<Map<String, dynamic>> post(String path, {Object? body}) async {
    final r = await _call(() => _dio.post(path, data: body));
    return (r.data as Map).cast<String, dynamic>();
  }

  /// POST whose 200 body is a JSON array (forward: one row per destination).
  Future<List<dynamic>> postList(String path, {Object? body}) async {
    final r = await _call(() => _dio.post(path, data: body));
    return (r.data as List).cast<dynamic>();
  }

  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    final r = await _call(() => _dio.put(path, data: body));
    return (r.data as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    final r = await _call(() => _dio.patch(path, data: body));
    return (r.data as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> delete(String path, {Object? body}) async {
    final r = await _call(() => _dio.delete(path, data: body));
    final data = r.data;
    // DELETE may legitimately return no content.
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required String fileField,
    required List<int> bytes,
    required String filename,
    String? contentType,
    Map<String, dynamic>? fields,
    Map<String, ({List<int> bytes, String filename, String contentType})>? extraFiles,
  }) async {
    final form = FormData.fromMap({
      fileField: MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: contentType != null ? DioMediaType.parse(contentType) : null,
      ),
      if (extraFiles != null)
        for (final e in extraFiles.entries)
          e.key: MultipartFile.fromBytes(
            e.value.bytes,
            filename: e.value.filename,
            contentType: DioMediaType.parse(e.value.contentType),
          ),
      if (fields != null) ...fields,
    });
    final r = await _call(() => _dio.post(path, data: form));
    return (r.data as Map).cast<String, dynamic>();
  }

  /// Direct PUT of [bytes] to a presigned S3 URL (batch 5 upload flow). No
  /// Authorization header — the signature in the URL is the credential, and
  /// the declared Content-Type must match what the intent was signed for.
  /// Returns the `ETag` S3 answers with (needed to complete a multipart
  /// upload). [onProgress] reports bytes sent so far.
  Future<String> putToUrl(
    String url,
    List<int> bytes, {
    required String contentType,
    void Function(int sent, int total)? onProgress,
  }) async {
    final bare = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(minutes: 10),
      receiveTimeout: const Duration(minutes: 2),
    ));
    try {
      final r = await bare.put<dynamic>(
        url,
        data: Stream.fromIterable([bytes]),
        options: Options(
          headers: {
            Headers.contentTypeHeader: contentType,
            Headers.contentLengthHeader: bytes.length,
          },
        ),
        onSendProgress: onProgress,
      );
      usage?.addSent(bytes.length);
      final etag = r.headers.value('etag') ?? r.headers.value('ETag') ?? '';
      return etag.replaceAll('"', '');
    } on DioException catch (e) {
      throw ApiException('upload_put_failed', status: e.response?.statusCode);
    }
  }

  Future<Response<dynamic>> _call(Future<Response<dynamic>> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final detail = (e.response?.data is Map) ? (e.response!.data['detail']?.toString() ?? e.message ?? '') : (e.message ?? '');
      throw ApiException(detail, status: status);
    }
  }
}
