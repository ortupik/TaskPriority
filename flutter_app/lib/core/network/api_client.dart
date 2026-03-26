import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../app_config.dart';
import '../storage/token_storage.dart';

part 'api_client.g.dart';

@riverpod
ApiClient apiClient(Ref ref) {
  return ApiClient(ref);
}

class ApiClient {
  late final Dio _dio;
  final Ref _ref;

  ApiClient(this._ref) {
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiBase,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Content-Type': 'application/json'},
    ));

    _dio.interceptors.addAll([
      _AuthInterceptor(_ref, _dio),
      LogInterceptor(requestBody: false, responseBody: false),
    ]);
  }

  Dio get dio => _dio;

  // ── Convenience wrappers ──────────────────────────────────────────────────

  Future<Response<T>> get<T>(String path, {Map<String, dynamic>? params}) =>
      _dio.get(path, queryParameters: params);

  Future<Response<T>> post<T>(String path, {dynamic data}) =>
      _dio.post(path, data: data);

  Future<Response<T>> patch<T>(String path, {dynamic data}) =>
      _dio.patch(path, data: data);

  Future<Response<T>> delete<T>(String path) => _dio.delete(path);

  Future<Response<T>> postFormData<T>(String path, FormData formData) =>
      _dio.post(path, data: formData);
}

/// Injects the Bearer token and handles 401 → refresh → retry.
class _AuthInterceptor extends Interceptor {
  final Ref _ref;
  final Dio _dio;
  bool _isRefreshing = false;
  final List<_PendingRequest> _queue = [];

  _AuthInterceptor(this._ref, this._dio);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    // Skip auth header for login/refresh endpoints
    final skipPaths = ['/auth/login', '/auth/refresh'];
    final isSkipped = skipPaths.any((p) => options.path.contains(p));

    if (!isSkipped) {
      final storage = _ref.read(tokenStorageProvider);
      final token = await storage.getAccessToken();
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode != 401) {
      handler.next(err);
      return;
    }

    // Avoid refresh loop on the refresh endpoint itself
    if (err.requestOptions.path.contains('/auth/refresh')) {
      handler.next(err);
      return;
    }

    if (_isRefreshing) {
      // Queue the request until refresh completes
      _queue.add(_PendingRequest(err.requestOptions, handler));
      return;
    }

    _isRefreshing = true;

    try {
      final storage = _ref.read(tokenStorageProvider);
      final refreshToken = await storage.getRefreshToken();

      if (refreshToken == null) {
        _failAll(err);
        handler.next(err);
        return;
      }

      final resp = await _dio.post('/auth/refresh/', data: {'refresh_token': refreshToken});
      final newAccess = resp.data['access_token'] as String;
      final newRefresh = resp.data['refresh_token'] as String;

      await storage.saveTokens(accessToken: newAccess, refreshToken: newRefresh);

      // Retry original request
      err.requestOptions.headers['Authorization'] = 'Bearer $newAccess';
      final retried = await _dio.fetch(err.requestOptions);
      handler.resolve(retried);

      // Drain queue
      for (final pending in _queue) {
        pending.options.headers['Authorization'] = 'Bearer $newAccess';
        try {
          final r = await _dio.fetch(pending.options);
          pending.handler.resolve(r);
        } catch (e) {
          pending.handler.next(err);
        }
      }
    } catch (_) {
      // Refresh failed — force logout
      final storage = _ref.read(tokenStorageProvider);
      await storage.clearAll();
      _failAll(err);
      handler.next(err);
    } finally {
      _isRefreshing = false;
      _queue.clear();
    }
  }

  void _failAll(DioException err) {
    for (final pending in _queue) {
      pending.handler.next(err);
    }
  }
}

class _PendingRequest {
  final RequestOptions options;
  final ErrorInterceptorHandler handler;
  _PendingRequest(this.options, this.handler);
}

/// Parse a DioException into a human-readable message.
String parseApiError(DioException e) {
  final data = e.response?.data;
  if (data is Map && data['error'] != null) {
    return data['error']['message'] as String? ?? 'Unknown error';
  }
  if (e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout) {
    return 'Connection timed out. Check your network.';
  }
  if (e.type == DioExceptionType.connectionError) {
    return 'No connection. Working offline.';
  }
  return e.message ?? 'Network error';
}
