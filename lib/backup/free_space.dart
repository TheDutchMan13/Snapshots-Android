import 'package:photo_manager/photo_manager.dart';

import '../api/client.dart';
import 'backup_db.dart';

/// Photos and videos on this phone that are safely in Snapshots, so the phone's own copy can go.
class FreeSpace {
  FreeSpace._(this.items, this.total);

  /// The phone's items that may be removed, oldest first.
  final List<AssetEntity> items;

  /// How many were backed up in all (some may have changed on the phone since, or be in the PC's trash).
  final int total;

  /// Only items that (1) were sent to or found on Snapshots, (2) haven't changed on the phone since, and
  /// (3) Snapshots still has outside the trash, so nothing is removed from the phone that could be lost.
  static Future<FreeSpace> find(Api api) async {
    final db = await BackupDb.open();
    final sent = await db.sent();
    final unchanged = <String, AssetEntity>{};
    final sums = <String, String>{};
    for (final s in sent) {
      final a = await AssetEntity.fromId(s.localId);
      if (a == null || (a.modifiedDateSecond ?? 0) != s.modified) continue;
      unchanged[s.localId] = a;
      sums[s.localId] = s.sha1;
    }
    final kept = <String>{};
    final all = sums.values.toSet().toList();
    for (var i = 0; i < all.length; i += 1000) {
      final r = await api.post('/api/upload/check', {'sha1': all.sublist(i, i + 1000 > all.length ? all.length : i + 1000), 'kept': true});
      if (r['kept'] != true) {
        throw ApiError('Update Snapshots on the PC first: this version can\'t tell the phone which photos are safe to remove.');
      }
      kept.addAll([for (final h in r['have'] as List) h as String]);
    }
    final items = [for (final e in unchanged.entries) if (kept.contains(sums[e.key])) e.value]
      ..sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
    return FreeSpace._(items, sent.length);
  }

  List<AssetEntity> olderThan(int days) {
    final before = DateTime.now().subtract(Duration(days: days));
    return [for (final a in items) if (a.createDateTime.isBefore(before)) a];
  }

  /// Removes them from the phone. Android asks the person to confirm. Returns how many went.
  static Future<int> remove(List<AssetEntity> items) async {
    var gone = 0;
    final db = await BackupDb.open();
    for (var i = 0; i < items.length; i += 300) {
      final part = items.sublist(i, i + 300 > items.length ? items.length : i + 300);
      final removed = await PhotoManager.editor.deleteWithIds([for (final a in part) a.id]);
      if (removed.isEmpty) break; // the person said no
      await db.markFreed(removed);
      gone += removed.length;
    }
    return gone;
  }
}
