import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'backup_service.dart';
import 'backup_state.dart';

const _autoTask = 'snapshots-backup';
const _nowTask = 'snapshots-backup-now';

final _notification = ForegroundServiceConfig(
  notificationTitle: 'Backing up to Snapshots',
  notificationText: 'Sending new photos and videos to your PC',
  notificationChannelId: 'backup',
  notificationChannelName: 'Backup',
  notificationId: 4711,
);

/// Runs in its own background isolate, started by Android's WorkManager.
@pragma('vm:entry-point')
void backupDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await BackupRun(background: true).run();
    } catch (_) {
      // The status says what happened; WorkManager tries again on the next round.
    }
    return true;
  });
}

class Backup {
  static bool _ready = false;

  static Future<void> init() async {
    if (_ready) return;
    await Workmanager().initialize(backupDispatcher);
    _ready = true;
  }

  /// Turn the automatic backup on or off, with the current settings (Wi-Fi, charging).
  static Future<void> schedule() async {
    await init();
    final s = await BackupSettings.load();
    if (!s.enabled) {
      await Workmanager().cancelByUniqueName(_autoTask);
      return;
    }
    await Workmanager().registerPeriodicTask(
      _autoTask,
      _autoTask,
      frequency: const Duration(hours: 1),
      constraints: Constraints(
        networkType: s.wifiOnly ? NetworkType.unmetered : NetworkType.connected,
        requiresCharging: s.chargingOnly,
        requiresBatteryNotLow: true,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      foregroundServiceConfig: _notification,
    );
  }

  /// When the app opens (and after signing in): make sure the hourly backup is scheduled, and
  /// pick up the photos taken since the last run.
  static Future<void> onAppStart() async {
    try {
      final s = await BackupSettings.load();
      if (!s.enabled) return;
      await schedule();
      await now(charging: s.chargingOnly);
    } catch (_) {
      // Backup can still be started from its screen.
    }
  }

  /// One run, as soon as there is a network ("Back up now" doesn't wait for the charger).
  static Future<void> now({bool charging = false}) async {
    await init();
    final s = await BackupSettings.load();
    await Workmanager().registerOneOffTask(
      _nowTask,
      _nowTask,
      constraints: Constraints(
        networkType: s.wifiOnly ? NetworkType.unmetered : NetworkType.connected,
        requiresCharging: charging,
      ),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      foregroundServiceConfig: _notification,
    );
  }

  /// On Android 13 and newer, asks once for permission to show the "Backing up" notification.
  /// Backup works without it, just without the notification.
  static Future<void> askToNotify() async {
    try {
      await const MethodChannel('snapshots/notifications').invokeMethod<void>('ask');
    } catch (_) {
      // Not on Android (tests).
    }
  }

  /// The run notices this between files and finishes cleanly.
  static Future<void> stop() => BackupStatus.requestStop(true);

  /// After signing out or switching servers.
  static Future<void> cancelAll() async {
    await init();
    await BackupStatus.requestStop(true);
    await Workmanager().cancelAll();
  }
}
