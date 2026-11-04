import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';

/// One grid of photos (the timeline, an album, a person, a search…), loaded a page at a time.
class Feed extends ChangeNotifier {
  Feed(this.api, this.query, {this.pageSize = 120});

  final Api api;

  /// The filter, as /api/assets query parameters.
  final Map<String, dynamic> query;
  final int pageSize;

  final List<Asset> items = [];
  String? _next;
  bool done = false;
  bool loading = false;
  String? error;
  int _gen = 0;
  bool _disposed = false;

  bool get isEmpty => items.isEmpty && done;

  /// For a content search ("what's in the photo") everything comes at once.
  bool get _look => query['look'] == true;

  Future<void> loadMore() async {
    if (loading || done) return;
    loading = true;
    error = null;
    final gen = _gen;
    notifyListeners();
    try {
      final data = await api.get('/api/assets', query: {
        ...query,
        'limit': pageSize,
        if (_next != null) 'cursor': _next,
      });
      if (_disposed || gen != _gen) return;
      for (final j in (data['items'] as List)) {
        items.add(Asset(Map<String, dynamic>.from(j as Map)));
      }
      _next = data['next'] as String?;
      done = _next == null || _look;
    } catch (e) {
      // Any failure, also an answer that isn't Snapshots, shows a message with "Try again".
      if (gen == _gen) error = errorText(e);
    } finally {
      if (!_disposed && gen == _gen) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh() async {
    _gen++;
    items.clear();
    _next = null;
    done = false;
    loading = false;
    error = null;
    notifyListeners();
    await loadMore();
  }

  /// Start the grid at a month (older photos load as you scroll).
  Future<void> jumpTo(String month) async {
    _gen++;
    items.clear();
    final parts = month.split('-');
    var y = int.parse(parts[0]), m = int.parse(parts[1]) + 1;
    if (m > 12) {
      m = 1;
      y++;
    }
    _next = '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}|0';
    done = false;
    loading = false;
    error = null;
    notifyListeners();
    await loadMore();
  }

  void remove(Iterable<int> ids) {
    final gone = ids.toSet();
    items.removeWhere((a) => gone.contains(a.id));
    notifyListeners();
  }

  void changed() => notifyListeners();

  /// A screen can close (and dispose the feed) while a page is still loading: its answer is dropped.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    super.dispose();
  }
}
