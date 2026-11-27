import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
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

/// A sentence for any failure while loading: the server's own words, or a plain one when the
/// answer made no sense (for example a Wi-Fi sign-in page instead of Snapshots).
String errorText(Object e) => e is ApiError
    ? e.message
    : "Snapshots sent an answer the app didn't understand. If this Wi-Fi has a sign-in page, "
        'sign in with the browser first, then try again.';

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
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
      if (!await routeIsSafe()) {
        h.reject(DioException(requestOptions: o, error: ApiError(tailscaleOff), type: DioExceptionType.unknown));
        return;
      }
      if (token != null) o.headers['Authorization'] = 'Bearer $token';
      if (deviceCookie != null) o.headers['Cookie'] = 'snapshots_device=$deviceCookie';
      h.next(o);
    }));
  }

  static const tailscaleOff = 'Tailscale is off on this phone. Turn it on, then try again: without it, the PC\'s '
      'Tailscale address could belong to another device on this network, which would get your sign-in.';

  /// Is a VPN (Tailscale) carrying the phone's traffic just now? A seam for tests.
  static Future<bool> Function() vpnActive = () async {
    try {
      return (await Connectivity().checkConnectivity()).contains(ConnectivityResult.vpn);
    } catch (_) {
      return true; // can't tell: as before this check existed
    }
  };

  /// True for a 100.64.0.0/10 address. Tailscale uses these, but so do some mobile and hotel networks
  /// (carrier-grade NAT), where the same number can be someone else's device.
  static bool sharedRange(String input) {
    final host = Uri.tryParse(normalizeServer(input))?.host ?? '';
    final ip = host.split('.');
    if (ip.length != 4 || !ip.every((p) => int.tryParse(p) != null)) return false;
    final a = int.parse(ip[0]), b = int.parse(ip[1]);
    return a == 100 && b >= 64 && b <= 127;
  }

  bool _routeOk = true;
  DateTime _routeChecked = DateTime.fromMillisecondsSinceEpoch(0);

  /// For a 100.x address over plain http: only while Tailscale is on (checked at most every 10 seconds).
  /// Other addresses: always (the sign-in screen warns about plain http to them).
  Future<bool> routeIsSafe() async {
    if (!server.startsWith('http://') || !sharedRange(server)) return true;
    final now = DateTime.now();
    if (now.difference(_routeChecked) > const Duration(seconds: 10)) {
      _routeOk = await vpnActive();
      _routeChecked = now;
    }
    return _routeOk;
  }

  final String server;
  String? token;

  /// The server remembers this phone as a known device, so a stranger guessing passwords
  /// elsewhere doesn't lock it out.
  String? deviceCookie;

  /// Called when the server says the session is no longer valid.
  void Function()? onSignedOut;

  late final Dio dio;

  /// "100.64.1.2:8080" or "pc.tail1234.ts.net" -> "http://100.64.1.2:8080".
  static String normalizeServer(String input) {
    var s = input.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
    return s;
  }

  /// True for a plain http:// address that is not a Tailscale one (100.64.0.0/10 or *.ts.net):
  /// there the password and photos travel unencrypted over the network the phone is on.
  static bool unencrypted(String input) {
    final s = normalizeServer(input);
    if (!s.startsWith('http://')) return false;
    final host = Uri.tryParse(s)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    if (host.endsWith('.ts.net')) return false;
    final ip = host.split('.');
    if (ip.length == 4 && ip.every((p) => int.tryParse(p) != null)) {
      final a = int.parse(ip[0]), b = int.parse(ip[1]);
      if (a == 100 && b >= 64 && b <= 127) return false;
    }
    return true;
  }

  /// Headers for images and videos loaded straight from the server (none while the route isn't safe:
  /// see routeIsSafe, which every API request checks first).
  Map<String, String> get authHeaders => {if (token != null && _routeOk) 'Authorization': 'Bearer $token'};

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
    if (e.error is ApiError) return e.error as ApiError;
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
