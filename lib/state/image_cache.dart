import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// The pictures kept on the phone. The library's own default keeps only 200 pictures for 30 days,
/// which empties itself while you scroll a big library; this one holds many more, and can be
/// emptied when somebody signs out or moves to another PC (so pictures of one library never
/// stay behind for the next).
class ImageStore {
  ImageStore._();

  static const maxPictures = 20000;
  static const keepDays = 120;

  /// Off in tests, which have no disk cache.
  static bool enabled = true;

  static CacheManager? _manager;

  /// Made when first needed (making it opens a folder on the phone).
  static CacheManager get manager => _manager ??= CacheManager(Config(
        'snapshotsImages',
        stalePeriod: const Duration(days: keepDays),
        maxNrOfCacheObjects: maxPictures,
      ));

  /// Forget every picture kept on the phone. Never throws: a cache that can't be emptied (or isn't
  /// there, as in tests) must not stop signing out.
  static Future<void> clear() async {
    if (!enabled) return;
    try {
      await manager.emptyCache();
    } catch (_) {}
  }
}
