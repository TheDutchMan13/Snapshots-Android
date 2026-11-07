import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// What the phone has already sent to Snapshots, so it isn't read and hashed again.
///
/// One row per photo or video on the phone (its MediaStore id). [modified] is the file's
/// modification time when it was handled: if the photo is edited on the phone, it is sent again.
class BackupDb {
  BackupDb._(this._db);

  final Database _db;

  static Future<BackupDb>? _shared;

  /// The one connection of this isolate. sqflite shares the native database between the app and
  /// the background worker, so closing it in one would close it for the other: it is never closed.
  static Future<BackupDb> open() => _shared ??= _open();

  static Future<BackupDb> _open() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'backup.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE items (
            local_id TEXT PRIMARY KEY,
            modified INTEGER NOT NULL,
            sha1 TEXT,
            status TEXT NOT NULL,       -- 'sent' (on the server), 'rejected', 'hashed' (not sent yet)
            server_id INTEGER,
            reason TEXT,
            name TEXT,
            at INTEGER NOT NULL
          )''');
      },
    );
    return BackupDb._(db);
  }

  /// local_id -> (modified, status, sha1) for everything known.
  Future<Map<String, ({int modified, String status, String? sha1})>> known() async {
    final rows = await _db.query('items', columns: ['local_id', 'modified', 'status', 'sha1']);
    return {
      for (final r in rows)
        r['local_id'] as String: (modified: r['modified'] as int, status: r['status'] as String, sha1: r['sha1'] as String?)
    };
  }

  Future<void> put(String localId, int modified, String status,
      {String? sha1, int? serverId, String? reason, String? name}) async {
    await _db.insert(
      'items',
      {
        'local_id': localId,
        'modified': modified,
        'sha1': sha1,
        'status': status,
        'server_id': serverId,
        'reason': reason,
        'name': name,
        'at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> count(String status) async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM items WHERE status = ?', [status])) ?? 0;

  Future<List<({String name, String reason})>> rejected({int limit = 50}) async {
    final rows = await _db.query('items', where: "status = 'rejected'", orderBy: 'at DESC', limit: limit);
    return [for (final r in rows) (name: (r['name'] as String?) ?? '', reason: (r['reason'] as String?) ?? '')];
  }

  /// Everything sent to (or found on) Snapshots, with the checksum it had then: what "free up space" may remove.
  Future<List<({String localId, int modified, String sha1})>> sent() async {
    final rows = await _db.query('items', columns: ['local_id', 'modified', 'sha1'], where: "status = 'sent' AND sha1 IS NOT NULL");
    return [for (final r in rows) (localId: r['local_id'] as String, modified: r['modified'] as int, sha1: r['sha1'] as String)];
  }

  /// Removed from the phone by "free up space": not offered again.
  Future<void> markFreed(List<String> localIds) async {
    final batch = _db.batch();
    for (final id in localIds) {
      batch.update('items', {'status': 'freed'}, where: 'local_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Forget everything (after switching to another server, everything is checked again).
  Future<void> clear() => _db.delete('items');

  /// Forget the files that were turned away, so they are tried again.
  Future<void> retryRejected() => _db.delete('items', where: "status = 'rejected'");
}
