import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/constants/api_routes.dart';
import '../../core/constants/app_constants.dart';
import 'token_storage.dart';

class ApiException implements Exception {
  final int? status;
  final String detail;
  ApiException(this.detail, {this.status});

  @override
  String toString() => 'ApiException($status): $detail';
}

/// Called by the interceptor when the refresh attempt itself is unrecoverable
/// (refresh token expired/revoked). Set by the DI layer so the client can
/// signal auth state to flip to signedOut without a circular import.
typedef SessionEndedCallback = void Function();

class ApiClient {
  final Dio _dio;
  final TokenStorage _tokens;

  // One-at-a-time refresh. Future completes when the in-flight refresh
  // finishes; null means no refresh is running. Must be reassigned on every
  // attempt — a single Completer cannot be reused.
  Future<void>? _refreshInFlight;

  SessionEndedCallback? onSessionEnded;

  ApiClient({TokenStorage? tokens})
      : _tokens = tokens ?? TokenStorage(),
        _dio = Dio(BaseOptions(
          baseUrl: AppConstants.apiBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          contentType: 'application/json',
        )) {
    _dio.interceptors.add(InterceptorsWrapper(
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
    // Bare Dio — no interceptor, no recursion.
    final bare = Dio(BaseOptions(baseUrl: AppConstants.apiBaseUrl));
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
  }) async {
    final form = FormData.fromMap({
      fileField: MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: contentType != null ? DioMediaType.parse(contentType) : null,
      ),
      if (fields != null) ...fields,
    });
    final r = await _call(() => _dio.post(path, data: form));
    return (r.data as Map).cast<String, dynamic>();
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
