import 'package:photo_manager/photo_manager.dart';

import '../api/client.dart';
import 'backup_db.dart';
import 'library_check.dart';

/// Photos and videos on this phone that are safely in Snapshots, so the phone's own copy can go.
class FreeSpace {
  FreeSpace._(this._api, this.items, this.total, this._sums, this._modified);

  final Api _api;

  /// The phone's items that may be removed, oldest first.
  final List<AssetEntity> items;

  /// How many were backed up in all (some may have changed on the phone since, or be in the PC's trash).
  final int total;

  final Map<String, String> _sums; // phone id -> SHA-1 of what was sent
  final Map<String, int> _modified; // phone id -> the file's time when it was sent

  /// Only items that (1) were sent to or found on Snapshots, (2) haven't changed on the phone since, and
  /// (3) Snapshots saw on the PC's disk just now, outside the trash. Nothing is offered that could be lost.
  static Future<FreeSpace> find(Api api) async {
    final db = await BackupDb.open();
    final sent = await db.sent();
    final onPhone = <String, AssetEntity>{};
    for (final s in sent) {
      final a = await AssetEntity.fromId(s.localId);
      if (a != null) onPhone[s.localId] = a;
    }
    final sums = unchangedSums(sent, (id) => onPhone[id]?.modifiedDateSecond ?? (onPhone.containsKey(id) ? 0 : null));
    final kept = await LibraryCheck.keptOnDisk(api, sums.values);
    final items = [for (final e in sums.entries) if (kept.contains(e.value.toLowerCase())) onPhone[e.key]!]
      ..sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
    return FreeSpace._(api, items, sent.length, sums, {for (final s in sent) s.localId: s.modified});
  }

  /// phone id -> SHA-1 for the sent items that are still on the phone ([modifiedOnPhone] is not null) and
  /// haven't changed there since they were sent.
  static Map<String, String> unchangedSums(
      Iterable<({String localId, int modified, String sha1})> sent, int? Function(String localId) modifiedOnPhone) {
    return {
      for (final s in sent)
        if (modifiedOnPhone(s.localId) == s.modified) s.localId: s.sha1,
    };
  }

  List<AssetEntity> olderThan(int days) {
    final before = DateTime.now().subtract(Duration(days: days));
    return [for (final a in items) if (a.createDateTime.isBefore(before)) a];
  }

  /// Removes them from the phone. Android asks the person to confirm. Says how many went, and how many
  /// were left because Snapshots couldn't confirm them any more.
  Future<({int gone, int held})> remove(List<AssetEntity> chosen) async {
    final db = await BackupDb.open();
    return removeChecked(
      api: _api,
      ids: [for (final a in chosen) a.id],
      sums: _sums,
      unchanged: (id) async {
        final a = await AssetEntity.fromId(id);
        return a != null && (a.modifiedDateSecond ?? 0) == _modified[id];
      },
      delete: PhotoManager.editor.deleteWithIds,
      freed: db.markFreed,
    );
  }

  /// The removal itself, a few hundred at a time. Right before each part, Snapshots is asked again
  /// whether it still sees those files on the PC's disk, and the phone whether they are still unchanged:
  /// anything not confirmed stays on the phone. [delete] returns the ids that really went (none: the
  /// person said no).
  static Future<({int gone, int held})> removeChecked({
    required Api api,
    required List<String> ids,
    required Map<String, String> sums,
    required Future<bool> Function(String id) unchanged,
    required Future<List<String>> Function(List<String> ids) delete,
    required Future<void> Function(List<String> ids) freed,
    int perStep = 300,
  }) async {
    var gone = 0, held = 0;
    for (var i = 0; i < ids.length; i += perStep) {
      final part = ids.sublist(i, i + perStep > ids.length ? ids.length : i + perStep);
      final same = <String>[];
      for (final id in part) {
        if (sums[id] != null && await unchanged(id)) same.add(id);
      }
      final kept = same.isEmpty ? const <String>{} : await LibraryCheck.keptOnDisk(api, [for (final id in same) sums[id]!]);
      final safe = [for (final id in same) if (kept.contains(sums[id]!.toLowerCase())) id];
      held += part.length - safe.length;
      if (safe.isEmpty) continue;
      final asked = safe.toSet();
      final removed = (await delete(safe)).where(asked.contains).toList();
      if (removed.isEmpty) break; // the person said no
      await freed(removed);
      gone += removed.length;
    }
    return (gone: gone, held: held);
  }
}
