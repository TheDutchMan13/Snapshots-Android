import 'dart:io';

import 'package:dio/dio.dart';

/// Something the server said no to, with the server's own words when it gave any.
class ApiError implements Exception {
  ApiError(this.message, {this.status});

  final String message;
  final int? status;

  bool get signedOut => status == 401;

  @override
  String toString() => message;
}

/// Talks to one Snapshots server. Every request carries the session token as a Bearer token.
class Api {
  Api({required String server, this.token, this.deviceCookie, this.onSignedOut})
      : server = normalizeServer(server) {
    dio = Dio(BaseOptions(
      baseUrl: this.server,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      // Snapshots refuses changes without this header unless they carry a Bearer token
      // (signing in doesn't have one yet).
      headers: {'Accept': 'application/json', 'X-Snapshots-Request': '1'},
    ));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      if (token != null) o.headers['Authorization'] = 'Bearer $token';
      if (deviceCookie != null) o.headers['Cookie'] = 'snapshots_device=$deviceCookie';
      h.next(o);
    }));
  }

  final String server;
  String? token;

  /// The server remembers this phone as a known device, so a stranger guessing passwords
  /// elsewhere doesn't lock it out.
  String? deviceCookie;

  /// Called when the server says the session is no longer valid.
  void Function()? onSignedOut;

  late final Dio dio;

  /// "100.64.1.2:8000" or "pc.tail1234.ts.net" -> "http://100.64.1.2:8000".
  static String normalizeServer(String input) {
    var s = input.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
    return s;
  }

  /// Headers for images and videos loaded straight from the server.
  Map<String, String> get authHeaders => {if (token != null) 'Authorization': 'Bearer $token'};

  String url(String path) => '$server$path';

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => dio.get(path, queryParameters: _clean(query)));

  Future<dynamic> post(String path, [Object? body]) => _send(() => dio.post(path, data: body ?? {}));

  Future<dynamic> put(String path, [Object? body]) => _send(() => dio.put(path, data: body ?? {}));

  Future<dynamic> patch(String path, [Object? body]) => _send(() => dio.patch(path, data: body ?? {}));

  Future<dynamic> delete(String path, {Object? body, Map<String, dynamic>? query}) =>
      _send(() => dio.delete(path, data: body, queryParameters: _clean(query)));

  Future<dynamic> _send(Future<Response<dynamic>> Function() call) async {
    try {
      final r = await call();
      _keepDeviceCookie(r);
      return r.data;
    } on DioException catch (e) {
      throw toApiError(e);
    }
  }

  void _keepDeviceCookie(Response<dynamic> r) {
    for (final c in r.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      if (c.startsWith('snapshots_device=')) {
        final v = c.substring('snapshots_device='.length).split(';').first;
        if (v.isNotEmpty) deviceCookie = v;
      }
    }
  }

  ApiError toApiError(DioException e) {
    final r = e.response;
    if (r == null) {
      if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout) {
        return ApiError("Snapshots didn't answer in time. Is the PC on, and is the phone connected to Tailscale?");
      }
      if (e.type == DioExceptionType.cancel) return ApiError('Cancelled.');
      return ApiError("Can't reach Snapshots at $server. Is the PC on, and is the phone connected to Tailscale?");
    }
    var message = 'Snapshots answered with an error (${r.statusCode}).';
    final data = r.data;
    if (data is Map && data['detail'] != null) {
      final d = data['detail'];
      if (d is String) {
        message = d;
      } else if (d is List && d.isNotEmpty && d.first is Map && d.first['msg'] != null) {
        message = '${d.first['msg']}';
      }
    }
    if (r.statusCode == 401 && token != null) onSignedOut?.call();
    return ApiError(message, status: r.statusCode);
  }

  static Map<String, dynamic>? _clean(Map<String, dynamic>? q) {
    if (q == null) return null;
    final out = <String, dynamic>{};
    q.forEach((k, v) {
      if (v == null) return;
      if (v is bool) {
        if (v) out[k] = 'true';
      } else {
        out[k] = v;
      }
    });
    return out;
  }
}
