import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/client.dart';

class User {
  User({required this.id, required this.username, required this.isAdmin});

  factory User.fromJson(Map<String, dynamic> j) =>
      User(id: j['id'] as int, username: j['username'] as String, isAdmin: j['is_admin'] == true);

  final int id;
  final String username;
  final bool isAdmin;

  Map<String, dynamic> toJson() => {'id': id, 'username': username, 'is_admin': isAdmin};
}

/// The result of the first login step.
class LoginStep {
  LoginStep.done(this.recoveryLeft) : ticket = null;
  LoginStep.needsCode(this.ticket) : recoveryLeft = null;

  final String? ticket;
  final int? recoveryLeft;

  bool get needsCode => ticket != null;
}

/// Which server this phone uses and who is signed in. Kept in Android's encrypted storage.
class Session extends ChangeNotifier {
  static const _storage = FlutterSecureStorage();
  static const _kServer = 'server', _kToken = 'token', _kUser = 'user', _kDevice = 'device';

  Api? api;
  User? user;
  String? serverVersion;
  bool loaded = false;

  bool get signedIn => api?.token != null && user != null;
  String get server => api?.server ?? '';

  /// The saved session, or null. Also used by the background backup.
  static Future<Api?> savedApi() async {
    final server = await _storage.read(key: _kServer);
    final token = await _storage.read(key: _kToken);
    if (server == null || token == null) return null;
    return Api(server: server, token: token, deviceCookie: await _storage.read(key: _kDevice));
  }

  Future<void> load() async {
    try {
      final server = await _storage.read(key: _kServer);
      if (server != null) {
        api = Api(
          server: server,
          token: await _storage.read(key: _kToken),
          deviceCookie: await _storage.read(key: _kDevice),
          onSignedOut: _expired,
        );
        final u = await _storage.read(key: _kUser);
        if (u != null && api!.token != null) user = _decodeUser(u);
      }
    } catch (_) {
      // Unreadable storage (for example after restoring a backup to a new phone): start over.
      await _storage.deleteAll();
      api = null;
      user = null;
    }
    loaded = true;
    notifyListeners();
  }

  /// Checks that a Snapshots server answers at this address. Returns its version.
  Future<String> checkServer(String address) async {
    final a = Api(server: address);
    if (a.server.isEmpty) throw ApiError('Type the address of your Snapshots PC.');
    final data = await a.get('/api/auth/state');
    if (data is! Map || !data.containsKey('needs_setup')) {
      throw ApiError("Something answered at ${a.server}, but it isn't Snapshots.");
    }
    if (data['needs_setup'] == true) {
      throw ApiError('Snapshots on that PC is not set up yet. Create the first account on the PC, then sign in here.');
    }
    final device = api?.server == a.server ? api?.deviceCookie : null;
    api = Api(server: a.server, deviceCookie: device ?? await _storage.read(key: _kDevice), onSignedOut: _expired);
    serverVersion = data['version'] as String?;
    await _storage.write(key: _kServer, value: api!.server);
    notifyListeners();
    return serverVersion ?? '';
  }

  Future<LoginStep> login(String username, String password) async {
    final data = await api!.post('/api/auth/login', {'username': username.trim(), 'password': password});
    if (data['two_step'] == true) return LoginStep.needsCode(data['ticket'] as String);
    await _signedIn(data);
    return LoginStep.done(null);
  }

  Future<LoginStep> loginCode(String ticket, String code) async {
    final data = await api!.post('/api/auth/login/code', {'ticket': ticket, 'code': code.replaceAll(' ', '')});
    await _signedIn(data);
    return LoginStep.done(data['recovery_left'] as int?);
  }

  Future<void> _signedIn(dynamic data) async {
    api!.token = data['token'] as String;
    user = User.fromJson(Map<String, dynamic>.from(data['user'] as Map));
    await _storage.write(key: _kToken, value: api!.token);
    await _storage.write(key: _kUser, value: _encodeUser(user!));
    if (api!.deviceCookie != null) await _storage.write(key: _kDevice, value: api!.deviceCookie);
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await api?.post('/api/auth/logout');
    } catch (_) {
      // Signed out here either way.
    }
    await _forget();
  }

  /// Use another server (also signs out).
  Future<void> changeServer() async {
    try {
      await api?.post('/api/auth/logout');
    } catch (_) {}
    for (final k in [_kToken, _kUser, _kServer]) {
      await _storage.delete(key: k);
    }
    api = null;
    user = null;
    notifyListeners();
  }

  void _expired() {
    _forget();
  }

  Future<void> _forget() async {
    api?.token = null;
    user = null;
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kUser);
    notifyListeners();
  }

  static String _encodeUser(User u) => '${u.id}\n${u.isAdmin ? 1 : 0}\n${u.username}';

  static User _decodeUser(String s) {
    final parts = s.split('\n');
    return User(id: int.parse(parts[0]), isAdmin: parts[1] == '1', username: parts.sublist(2).join('\n'));
  }
}
