import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/client.dart';
import '../backup/background.dart';
import '../backup/backup_db.dart';
import 'image_cache.dart';

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
  static const _kServer = 'server', _kToken = 'token', _kUser = 'user';

  /// The server the backup record (backup.db) belongs to. Kept after "Use another PC".
  static const _kBackupServer = 'backup_server';

  /// Older versions kept one device cookie for whatever server was used.
  static const _kOldDevice = 'device';

  /// Each server's device cookie is kept apart, so one PC's cookie is never sent to another.
  static String _deviceKey(String server) => 'device|$server';

  /// Stops the backup and forgets what was sent. Replaced in tests.
  @visibleForTesting
  static Future<void> Function() forgetBackup = () async {
    await Backup.cancelAll();
    await (await BackupDb.open()).clear();
  };

  Api? api;
  User? user;
  String? serverVersion;
  bool loaded = false;

  /// The oldest Snapshots this app is made for (the README says the same; a test keeps them equal).
  static const minServerVersion = '0.14.7';

  /// Is [version] (like "0.14.7") at least [minimum]? Anything that isn't dotted numbers counts as unknown: true.
  static bool versionAtLeast(String? version, [String minimum = minServerVersion]) {
    List<int>? parse(String? v) {
      final parts = (v ?? '').trim().split('.');
      final nums = [for (final p in parts) int.tryParse(p)];
      return parts.isEmpty || nums.contains(null) ? null : nums.cast<int>();
    }

    final a = parse(version), b = parse(minimum);
    if (a == null || b == null) return true;
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return true;
  }

  /// True when the PC runs a Snapshots older than the app needs for the safety checks.
  bool get serverTooOld => serverVersion != null && !versionAtLeast(serverVersion);

  /// Ask the PC which version it runs (the address may have been saved before this app kept it).
  Future<void> refreshServerVersion() async {
    try {
      final h = await api?.get('/api/health');
      final v = h is Map ? h['version'] as String? : null;
      if (v != null && v != serverVersion) {
        serverVersion = v;
        notifyListeners();
      }
    } catch (_) {}
  }

  bool get signedIn => api?.token != null && user != null;
  String get server => api?.server ?? '';

  /// The saved session, or null. Also used by the background backup.
  static Future<Api?> savedApi() async {
    final server = await _storage.read(key: _kServer);
    final token = await _storage.read(key: _kToken);
    if (server == null || token == null) return null;
    return Api(server: server, token: token, deviceCookie: await _device(server));
  }

  /// This server's device cookie (or the old single one, if it was made for this server).
  static Future<String?> _device(String server) async {
    final own = await _storage.read(key: _deviceKey(server));
    if (own != null) return own;
    final old = await _storage.read(key: _kOldDevice);
    if (old != null && await _storage.read(key: _kServer) == server) return old;
    return null;
  }

  /// Moves the old single device cookie to its server's own key, or drops it when its server
  /// isn't known any more.
  static Future<void> _moveOldDevice() async {
    final old = await _storage.read(key: _kOldDevice);
    if (old == null) return;
    final server = await _storage.read(key: _kServer);
    if (server != null && await _storage.read(key: _deviceKey(server)) == null) {
      await _storage.write(key: _deviceKey(server), value: old);
    }
    await _storage.delete(key: _kOldDevice);
  }

  Future<void> load() async {
    try {
      await _moveOldDevice();
      final server = await _storage.read(key: _kServer);
      if (server != null) {
        api = Api(
          server: server,
          token: await _storage.read(key: _kToken),
          deviceCookie: await _storage.read(key: _deviceKey(server)),
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
    // Another PC than the one the phone backed up to: what was sent there says nothing about
    // this one, so the backup starts over (photos the PC already has are still skipped).
    final before = await _storage.read(key: _kBackupServer) ?? await _storage.read(key: _kServer);
    if (before != null && before != a.server) {
      await forgetBackup();
      await ImageStore.clear(); // another PC, another library: no pictures of the old one stay behind
    }
    await _storage.write(key: _kBackupServer, value: a.server);
    final device = api?.server == a.server ? api?.deviceCookie : null;
    api = Api(server: a.server, deviceCookie: device ?? await _device(a.server), onSignedOut: _expired);
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
    if (api!.deviceCookie != null) await _storage.write(key: _deviceKey(api!.server), value: api!.deviceCookie);
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await api?.post('/api/auth/logout');
    } catch (_) {
      // Signed out here either way.
    }
    await ImageStore.clear();
    await _forget();
  }

  /// Use another server (also signs out).
  Future<void> changeServer() async {
    try {
      await api?.post('/api/auth/logout');
    } catch (_) {}
    await ImageStore.clear();
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
