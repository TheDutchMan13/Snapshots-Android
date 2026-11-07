import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/feed.dart';
import 'albums_screen.dart';
import 'media.dart';
import 'theme.dart';
import 'viewer.dart';

String whenText(String at) {
  final t = DateTime.tryParse(at);
  if (t == null) return '';
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  if (diff.inDays < 1 && now.day == t.day) return DateFormat.jm().format(t);
  if (diff.inDays < 7) return DateFormat.E().add_jm().format(t);
  return DateFormat.yMMMd().format(t);
}

/// The comments on a photo or an album, with a box to add one. Returns how many there are now.
Future<int?> showComments(BuildContext context, {int? assetId, int? albumId}) => showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: _Comments(path: assetId != null ? '/api/assets/$assetId/comments' : '/api/albums/$albumId/comments'),
      ),
    );

class _Comments extends StatefulWidget {
  const _Comments({required this.path});

  final String path;

  @override
  State<_Comments> createState() => _CommentsState();
}

class _CommentsState extends State<_Comments> {
  List<Map>? _items;
  String? _error;
  bool _sending = false;
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await apiOf(context).get(widget.path);
      if (mounted) setState(() => _items = [for (final c in r['comments'] as List) c as Map]);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final c = await apiOf(context).post(widget.path, {'text': text});
      _text.clear();
      if (mounted) setState(() => _items = [...?_items, c as Map]);
    } on ApiError catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(Map c) async {
    final ok = await confirm(context, 'Delete this comment?', '"${c['text']}"', ok: 'Delete', danger: true);
    if (!ok || !mounted) return;
    try {
      await apiOf(context).delete('/api/comments/${c['id']}');
      if (mounted) setState(() => _items = [for (final x in _items ?? const <Map>[]) if (x['id'] != c['id']) x]);
    } on ApiError catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final items = _items;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, items?.length);
      },
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .75),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(alignment: Alignment.centerLeft, child: Text('Comments', style: t.textTheme.titleLarge)),
            ),
            Flexible(
              child: items == null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: _error == null ? const CircularProgressIndicator() : Text(_error!, textAlign: TextAlign.center),
                    )
                  : items.isEmpty
                      ? const Padding(padding: EdgeInsets.all(24), child: Text('No comments yet. Everyone who uses Snapshots sees what you write here.', textAlign: TextAlign.center))
                      : ListView(shrinkWrap: true, children: [
                          for (final c in items)
                            ListTile(
                              title: Text.rich(TextSpan(children: [
                                TextSpan(text: c['user'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                                TextSpan(text: '  ${whenText(c['created_at'] as String)}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                              ])),
                              subtitle: Text(c['text'] as String, style: t.textTheme.bodyMedium),
                              trailing: c['can_delete'] == true
                                  ? IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(c))
                                  : null,
                            ),
                        ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(hintText: 'Add a comment', counterText: ''),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(
                  tooltip: 'Send',
                  icon: _sending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                  onPressed: _send,
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// What others commented and added to albums, newest first. Opening it marks everything as seen.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  final List<Map> _items = [];
  String? _next;
  bool _loading = false, _started = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _more(first: true);
  }

  Future<void> _more({bool first = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    final api = apiOf(context);
    try {
      final r = await api.get('/api/activity', query: {'limit': 50, if (!first && _next != null) 'before': _next});
      if (!mounted) return;
      setState(() {
        if (first) _items.clear();
        _items.addAll([for (final i in r['items'] as List) i as Map]);
        _next = r['next'] as String?;
        _error = null;
        _started = true;
      });
      if (first) await api.post('/api/activity/seen');
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openAsset(Map asset) async {
    if (asset['trashed'] == true) {
      showMessage(context, 'That photo is in the trash.');
      return;
    }
    final api = apiOf(context);
    final feed = Feed.fixed(api, () async => [Asset(Map<String, dynamic>.from(await api.get('/api/assets/${asset['id']}') as Map))]);
    await feed.loadMore();
    if (!mounted) return;
    if (feed.items.isEmpty) {
      showMessage(context, feed.error ?? "That photo can't be opened any more.");
      feed.dispose();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => Viewer(feed: feed, index: 0)));
    feed.dispose();
  }

  Future<void> _openAlbum(int id) async {
    try {
      final r = await apiOf(context).get('/api/albums/$id');
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AlbumScreen(album: Album(Map<String, dynamic>.from(r as Map)))));
    } on ApiError catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Widget _tile(Map i) {
    final t = Theme.of(context);
    final who = i['mine'] == true ? 'You' : i['user'] as String;
    final asset = i['asset'] as Map?;
    final album = i['album'] as Map?;
    Widget? thumb;
    String text;
    VoidCallback? open;
    if (i['kind'] == 'added') {
      text = '$who added ${i['count'] == 1 ? 'a photo' : '${i['count']} items'} to ${album?['name']}';
      thumb = ServerThumb('/api/assets/${i['cover']}/thumb?v=${i['cover_v'] ?? ''}');
      open = () => _openAlbum(album!['id'] as int);
    } else if (asset != null) {
      text = '$who commented on a photo: "${i['text']}"';
      thumb = ServerThumb('/api/assets/${asset['id']}/thumb?v=${asset['v'] ?? ''}');
      open = () => _openAsset(asset);
    } else {
      text = '$who commented on ${album?['name'] ?? 'an album'}: "${i['text']}"';
      open = album == null ? null : () => _openAlbum(album['id'] as int);
    }
    return ListTile(
      leading: SizedBox(
        width: 52,
        height: 52,
        child: ClipRRect(borderRadius: BorderRadius.circular(6), child: thumb ?? const ColoredBox(color: Colors.black12, child: Icon(Icons.photo_album_outlined))),
      ),
      title: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text(whenText(i['at'] as String)),
      trailing: i['new'] == true ? Icon(Icons.circle, size: 10, color: t.colorScheme.primary) : null,
      onTap: open,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: RefreshIndicator(
        onRefresh: () => _more(first: true),
        child: ListView(children: [
          for (final i in _items) _tile(i),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Text(_error!, textAlign: TextAlign.center),
                OutlinedButton(onPressed: () => _more(first: !_started), child: const Text('Try again')),
              ]),
            )
          else if (_loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_started && _items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('Nothing yet. Comments and photos others add to albums show up here.', textAlign: TextAlign.center),
            )
          else if (_next != null)
            Padding(padding: const EdgeInsets.all(16), child: OutlinedButton(onPressed: _more, child: const Text('Show older'))),
        ]),
      ),
    );
  }
}
