import '../api/client.dart';

/// Asks Snapshots which files (by SHA-1) are in the library right now.
///
/// Snapshots keeps its records when a folder on the PC is emptied or a drive is unplugged, so "it has a
/// record" is not "the photo is safe". A Snapshots that looks for the files on its disk says so with
/// `verified: true`; an older one answers from its records, and is not trusted with anything that could
/// cost a photo.
class LibraryCheck {
  static const _perRequest = 1000;

  static const needsNewerSnapshots =
      "Update Snapshots on the PC first: this version can't tell the phone which photos are safe to remove.";

  /// Of [hashes], the ones Snapshots saw on its disk just now, outside the trash. Only these may be
  /// removed from the phone. Throws if the PC's Snapshots can't promise that.
  static Future<Set<String>> keptOnDisk(Api api, Iterable<String> hashes) async {
    final all = _clean(hashes);
    final kept = <String>{};
    for (var i = 0; i < all.length; i += _perRequest) {
      final part = all.sublist(i, i + _perRequest > all.length ? all.length : i + _perRequest);
      final r = await api.post('/api/upload/check', {'sha1': part, 'kept': true});
      if (r is! Map || r['kept'] != true || r['verified'] != true || r['have'] is! List) {
        throw ApiError(needsNewerSnapshots);
      }
      final asked = part.toSet();
      // Only what was asked about counts, whatever the answer holds.
      kept.addAll([for (final h in r['have'] as List) '$h'.toLowerCase()].where(asked.contains));
    }
    return kept;
  }

  /// Of [hashes] (photos this phone sent before), the ones Snapshots no longer has: their files are gone
  /// from the PC, so they must be sent again. Null if the PC's Snapshots can't tell (an older version).
  /// A photo on a drive that isn't connected to the PC still counts as there.
  static Future<Set<String>?> lost(Api api, Iterable<String> hashes) async {
    final all = _clean(hashes);
    final lost = <String>{};
    for (var i = 0; i < all.length; i += _perRequest) {
      final part = all.sublist(i, i + _perRequest > all.length ? all.length : i + _perRequest);
      final r = await api.post('/api/upload/check', {'sha1': part});
      if (r is! Map || r['verified'] != true || r['have'] is! List) return null;
      final have = {for (final h in r['have'] as List) '$h'.toLowerCase()};
      lost.addAll(part.where((h) => !have.contains(h)));
    }
    return lost;
  }

  static List<String> _clean(Iterable<String> hashes) =>
      {for (final h in hashes) if (h.length == 40) h.toLowerCase()}.toList();
}
