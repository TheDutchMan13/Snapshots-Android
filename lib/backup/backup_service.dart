import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../api/client.dart';
import '../state/session.dart';
import 'backup_db.dart';
import 'backup_state.dart';

/// The permission the backup needs: photos and videos, with their location (without it,
/// Android hands out copies with the GPS position removed).
const backupPermission = PermissionRequestOption(
  androidPermission: AndroidPermission(type: RequestType.common, mediaLocation: true),
);

/// Sends the phone's photos and videos to Snapshots.
///
/// 1. List the photos in the chosen albums and skip the ones already handled (by id and
///    modification time).
/// 2. Hash the rest (SHA-1 of the whole file, as the server does) and ask the server which
///    hashes it already has: those are done without uploading.
/// 3. Upload the others one by one.
///
/// Runs in the background worker; "Back up now" starts the same worker.
class BackupRun {
  BackupRun({required this.background});

  final bool background;
  final status = BackupStatus();
  late BackupDb _db;
  late Api _api;
  int _sent = 0, _already = 0, _rejected = 0, _failed = 0;

  /// Failed uploads in a row (saving on the PC failed): after a few, stop until the next run.
  int _failedInRow = 0;
  DateTime _lastBeat = DateTime(0);

  /// Returns a sentence for the Backup screen.
  Future<String> run() async {
    final previous = await BackupStatus.load();
    if (previous.running) return 'A backup is already running.';
    // Claim the backup, wait, and check nobody else claimed it meanwhile (the hourly run and
    // "Back up now" can start at the same moment, in two isolates of the same process).
    final me = '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
    status
      ..owner = me
      ..lastFinished = previous.lastFinished
      ..lastResult = previous.lastResult
      ..lastSent = previous.lastSent;
    await _beat('Starting', force: true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if ((await BackupStatus.load()).owner != me) return 'A backup is already running.';
    await BackupStatus.requestStop(false);
    // Keep saying "alive" while one big file is hashed or uploaded.
    final alive = Timer.periodic(const Duration(seconds: 30), (_) => _beat(status.phase, force: true));
    String result;
    try {
      result = await _run();
    } on ApiError catch (e) {
      result = e.message;
    } catch (e) {
      result = 'The backup stopped: $e';
    } finally {
      alive.cancel();
    }
    status
      ..heartbeat = 0
      ..phase = ''
      ..current = ''
      ..lastFinished = DateTime.now().millisecondsSinceEpoch
      ..lastResult = result
      ..lastSent = _sent;
    await status.save();
    return result;
  }

  Future<void> _beat(String phase, {bool force = false}) async {
    status
      ..phase = phase
      ..heartbeat = DateTime.now().millisecondsSinceEpoch;
    final now = DateTime.now();
    if (force || now.difference(_lastBeat) > const Duration(milliseconds: 700)) {
      _lastBeat = now;
      await status.save();
    }
  }

  Future<bool> _stopped() async => (await BackupStatus.load()).stopRequested;

  Future<String> _run() async {
    final settings = await BackupSettings.load();
    final api = await Session.savedApi();
    if (api == null) return 'Sign in to back up.';
    _api = api;

    // Asking Android for the permission state needs an app window, which the background worker
    // doesn't have; there, listing the albums simply fails or comes back empty without access.
    if (!background) {
      final perm = await PhotoManager.getPermissionState(requestOption: backupPermission);
      if (!perm.hasAccess) return _noAccess;
    }

    if (settings.wifiOnly) {
      final net = await Connectivity().checkConnectivity();
      if (!net.contains(ConnectivityResult.wifi) && !net.contains(ConnectivityResult.ethernet)) {
        return 'Waiting for Wi-Fi.';
      }
    }

    // Is Snapshots reachable? (A clear message beats a failure on the first upload.)
    await _api.get('/api/status');

    _db = await BackupDb.open();
    {
      await _beat('Looking for new photos', force: true);
      List<AssetEntity> assets;
      try {
        assets = await _choose(settings);
      } on PlatformException {
        return _noAccess;
      } on StateError catch (e) {
        return e.message;
      }
      final known = await _db.known();
      final todo = <AssetEntity>[];
      for (final a in assets) {
        final k = known[a.id];
        final modified = a.modifiedDateSecond ?? 0;
        if (k != null && k.modified == modified && (k.status == 'sent' || k.status == 'rejected')) continue;
        todo.add(a);
      }
      status
        ..total = todo.length
        ..done = 0;
      if (todo.isEmpty) return _summary(assets.length);

      for (var i = 0; i < todo.length; i += 50) {
        if (await _stopped()) return 'Stopped. ${_counts()}';
        await _batch(todo.sublist(i, i + 50 > todo.length ? todo.length : i + 50), known);
      }
      return _summary(assets.length);
    }
  }

  static const _noAccess =
      'Snapshots needs access to your photos and videos. Open the Backup screen and tap "Allow access".';

  String _counts() {
    final parts = <String>[
      if (_sent > 0) '$_sent sent',
      if (_already > 0) '$_already were already in Snapshots',
      if (_rejected > 0) "$_rejected couldn't be backed up",
      if (_failed > 0) "$_failed couldn't be saved on the PC and will be tried again",
    ];
    return parts.isEmpty ? '' : '${parts.join(', ')}.';
  }

  String _summary(int total) {
    final c = _counts();
    return c.isEmpty ? 'Everything is backed up ($total on this phone).' : 'Done: $c';
  }

  /// The photos and videos in the chosen albums, newest first, without repeats.
  Future<List<AssetEntity>> _choose(BackupSettings s) async {
    final type = s.videos ? RequestType.common : RequestType.image;
    final paths = await PhotoManager.getAssetPathList(type: type, hasAll: true);
    List<AssetPathEntity> chosen;
    if (s.allAlbums) {
      chosen = paths.where((p) => p.isAll).toList();
    } else if (s.albums.isNotEmpty) {
      chosen = paths.where((p) => s.albums.contains(p.id) && !p.isAll).toList();
    } else {
      chosen = paths.where((p) => !p.isAll && p.name.toLowerCase() == 'camera').toList();
      if (chosen.isEmpty) {
        throw StateError('This phone has no folder called Camera. Pick the folders to back up on the Backup screen.');
      }
    }
    final seen = <String>{};
    final out = <AssetEntity>[];
    for (final p in chosen) {
      final n = await p.assetCountAsync;
      for (var page = 0; page * 500 < n; page++) {
        for (final a in await p.getAssetListPaged(page: page, size: 500)) {
          if (a.type != AssetType.image && a.type != AssetType.video) continue;
          if (!s.videos && a.type == AssetType.video) continue;
          if (seen.add(a.id)) out.add(a);
        }
        await _beat('Looking for new photos');
      }
    }
    return out;
  }

  Future<void> _batch(List<AssetEntity> batch, Map<String, ({int modified, String status, String? sha1})> known) async {
    final hashed = <({AssetEntity a, File f, String sha1, String name, bool temp})>[];
    try {
      await _hashAndSend(batch, known, hashed);
    } finally {
      // Android 10 hands out copies in the app's cache: never leave them behind.
      for (final h in hashed) {
        if (h.temp) {
          try {
            await h.f.delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _hashAndSend(List<AssetEntity> batch, Map<String, ({int modified, String status, String? sha1})> known,
      List<({AssetEntity a, File f, String sha1, String name, bool temp})> hashed) async {
    // 1. Hash.
    for (final a in batch) {
      if (await _stopped()) return;
      final name = await _name(a);
      status.current = name;
      await _beat('Checking');
      File? f;
      try {
        f = await a.originFile;
      } catch (_) {
        f = null;
      }
      if (f == null || !await f.exists()) {
        _rejected++;
        await _done(a, 'rejected', name: name, reason: "Couldn't read the file on the phone.");
        continue;
      }
      final k = known[a.id];
      String hash;
      if (k != null && k.sha1 != null && k.modified == (a.modifiedDateSecond ?? 0)) {
        hash = k.sha1!;
      } else {
        hash = (await sha1.bind(f.openRead()).first).toString();
        await _db.put(a.id, a.modifiedDateSecond ?? 0, 'hashed', sha1: hash, name: name);
      }
      hashed.add((a: a, f: f, sha1: hash, name: name, temp: await _isTemp(f)));
    }
    if (hashed.isEmpty) return;

    // 2. Which does the server have already?
    final r = await _api.post('/api/upload/check', {'sha1': [for (final h in hashed) h.sha1]});
    final have = {for (final h in (r['have'] as List)) '$h'};

    // 3. Upload the rest.
    for (final h in hashed) {
      if (have.contains(h.sha1)) {
        _already++;
        await _done(h.a, 'sent', sha1: h.sha1, name: h.name);
        continue;
      }
      if (await _stopped()) return;
      status.current = h.name;
      await _beat('Uploading', force: true);
      await _upload(h.a, h.f, h.sha1, h.name);
    }
  }

  Future<void> _upload(AssetEntity a, File f, String hash, String name) async {
    final form = FormData.fromMap({'files': await MultipartFile.fromFile(f.path, filename: name)});
    Response<dynamic> resp;
    try {
      resp = await _api.dio.post('/api/upload',
          data: form,
          options: Options(receiveTimeout: const Duration(minutes: 10), sendTimeout: null),
          onSendProgress: (sent, total) => _beat('Uploading'));
    } on DioException catch (e) {
      final err = _api.toApiError(e);
      final code = err.status;
      // This one file was refused (too big for a proxy in between, or 413 for a file over the
      // PC's limit): note it and go on with the others. Without a connection, signed out, the
      // library drive offline or full (507): stop for now; the file is tried again next time.
      if (code != null && code >= 400 && code < 500 && code != 401 && code != 409 && code != 429) {
        _rejected++;
        await _done(a, 'rejected', sha1: hash, name: name, reason: err.message);
        return;
      }
      throw err;
    }
    final results = (resp.data['results'] as List?) ?? const [];
    final res = results.isNotEmpty ? Map<String, dynamic>.from(results.first as Map) : <String, dynamic>{};
    final st = uploadOutcome(res);
    final reason = res['reason'] as String? ?? 'Rejected by Snapshots.';
    if (st == 'retry') {
      // Saving failed on the PC (a full or busy drive, say): not the file's fault. It stays
      // "hashed", so the next run sends it again.
      _failed++;
      await _done(a, 'hashed', sha1: hash, name: name, reason: reason);
      if (++_failedInRow >= 3) throw ApiError('Snapshots could not save the photos on the PC: $reason');
      return;
    }
    _failedInRow = 0;
    if (st == 'rejected') {
      _rejected++;
      await _done(a, 'rejected', sha1: hash, name: name, reason: reason);
      return;
    }
    final id = res['id'] as int?;
    if (st == 'added') {
      _sent++;
      if (id != null) await _fixDate(a, id);
    } else {
      _already++;
    }
    await _done(a, 'sent', sha1: hash, serverId: id, name: name);
  }

  /// What the server said about one uploaded file: 'added', 'duplicate', 'restored', 'rejected' (the file
  /// itself was turned away, like an unsupported type) or 'retry' (saving failed on the PC).
  static String uploadOutcome(Map<String, dynamic> res) {
    final st = res['status'] as String? ?? 'rejected';
    if (st == 'rejected' && '${res['reason'] ?? ''}'.startsWith('Upload failed')) return 'retry';
    return st;
  }

  /// Snapshots dates a photo from the date inside it, or in its name. A file with neither (some
  /// screenshots, downloads, edited copies) would get the upload time: give it the phone's date.
  Future<void> _fixDate(AssetEntity a, int id) async {
    try {
      final j = await _api.get('/api/assets/$id');
      final server = DateTime.tryParse('${j['taken_at']}');
      final phone = a.createDateTime;
      if (server == null || phone.year < 1990) return;
      final sinceUpload = DateTime.now().difference(server).abs();
      final apart = server.difference(phone).abs();
      if (sinceUpload < const Duration(minutes: 10) && apart > const Duration(hours: 1)) {
        final local = phone.toLocal();
        String two(int n) => n.toString().padLeft(2, '0');
        final iso = '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)}'
            'T${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
        await _api.post('/api/assets/details', {'ids': [id], 'taken_at': iso});
      }
    } catch (_) {
      // The photo is backed up either way.
    }
  }

  Future<void> _done(AssetEntity a, String st, {String? sha1, int? serverId, String? name, String? reason}) async {
    await _db.put(a.id, a.modifiedDateSecond ?? 0, st, sha1: sha1, serverId: serverId, name: name, reason: reason);
    status.done++;
    await _beat(status.phase);
  }

  static Future<String> _name(AssetEntity a) async {
    var n = a.title ?? '';
    if (n.isEmpty) {
      try {
        n = await a.titleAsync;
      } catch (_) {}
    }
    if (n.isEmpty) n = '${a.type == AssetType.video ? 'VID' : 'IMG'}_${a.id}${a.type == AssetType.video ? '.mp4' : '.jpg'}';
    return n;
  }

  /// On Android 10 the plugin copies the file into the app's cache first; delete those copies.
  static Future<bool> _isTemp(File f) async {
    final dirs = <String>[(await getTemporaryDirectory()).path];
    try {
      final ext = await getExternalCacheDirectories();
      if (ext != null) dirs.addAll(ext.map((d) => d.path));
    } catch (_) {}
    return dirs.any((d) => f.path.startsWith(d));
  }
}
