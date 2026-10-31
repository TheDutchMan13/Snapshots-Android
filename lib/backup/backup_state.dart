import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The backup choices. Kept with SharedPreferencesAsync so the background worker always sees
/// the latest values.
class BackupSettings {
  BackupSettings({
    this.enabled = false,
    this.albums = const [],
    this.allAlbums = false,
    this.videos = true,
    this.wifiOnly = true,
    this.chargingOnly = false,
  });

  /// Back up automatically in the background.
  bool enabled;

  /// The phone's albums (folders) to back up, by id. Empty and [allAlbums] false: the camera.
  List<String> albums;
  bool allAlbums;
  bool videos;
  bool wifiOnly;
  bool chargingOnly;

  static const _key = 'backup.settings';

  static Future<BackupSettings> load() async {
    final raw = await SharedPreferencesAsync().getString(_key);
    if (raw == null) return BackupSettings();
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return BackupSettings(
        enabled: j['enabled'] == true,
        albums: [for (final a in (j['albums'] as List? ?? const [])) '$a'],
        allAlbums: j['all_albums'] == true,
        videos: j['videos'] != false,
        wifiOnly: j['wifi_only'] != false,
        chargingOnly: j['charging_only'] == true,
      );
    } catch (_) {
      return BackupSettings();
    }
  }

  Future<void> save() => SharedPreferencesAsync().setString(
        _key,
        jsonEncode({
          'enabled': enabled,
          'albums': albums,
          'all_albums': allAlbums,
          'videos': videos,
          'wifi_only': wifiOnly,
          'charging_only': chargingOnly,
        }),
      );
}

/// How the backup is going, written by whichever run is working (the app or the background
/// worker) and read by the Backup screen.
class BackupStatus {
  BackupStatus({
    this.heartbeat = 0,
    this.phase = '',
    this.done = 0,
    this.total = 0,
    this.current = '',
    this.lastFinished = 0,
    this.lastResult = '',
    this.lastSent = 0,
    this.stopRequested = false,
    this.owner = '',
  });

  /// When the running backup last said it was alive (ms). Older than [staleAfter]: not running.
  int heartbeat;
  String phase;
  int done;
  int total;
  String current;
  int lastFinished;
  String lastResult;
  int lastSent;
  bool stopRequested;

  /// Which run holds the backup (a random token), so two runs never work at the same time.
  String owner;

  static const staleAfter = Duration(minutes: 3);
  static const _key = 'backup.status';
  static const _stopKey = 'backup.stop';

  bool get running =>
      heartbeat > 0 && DateTime.now().millisecondsSinceEpoch - heartbeat < staleAfter.inMilliseconds;

  static Future<BackupStatus> load() async {
    final prefs = SharedPreferencesAsync();
    final raw = await prefs.getString(_key);
    final stop = await prefs.getBool(_stopKey) ?? false;
    if (raw == null) return BackupStatus(stopRequested: stop);
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return BackupStatus(
        heartbeat: j['heartbeat'] as int? ?? 0,
        phase: j['phase'] as String? ?? '',
        done: j['done'] as int? ?? 0,
        total: j['total'] as int? ?? 0,
        current: j['current'] as String? ?? '',
        lastFinished: j['last_finished'] as int? ?? 0,
        lastResult: j['last_result'] as String? ?? '',
        lastSent: j['last_sent'] as int? ?? 0,
        stopRequested: stop,
        owner: j['owner'] as String? ?? '',
      );
    } catch (_) {
      return BackupStatus(stopRequested: stop);
    }
  }

  Future<void> save() => SharedPreferencesAsync().setString(
        _key,
        jsonEncode({
          'heartbeat': heartbeat,
          'phase': phase,
          'done': done,
          'total': total,
          'current': current,
          'last_finished': lastFinished,
          'last_result': lastResult,
          'last_sent': lastSent,
          'owner': owner,
        }),
      );

  static Future<void> requestStop(bool value) => SharedPreferencesAsync().setBool(_stopKey, value);
}
