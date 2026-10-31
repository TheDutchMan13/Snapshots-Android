import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/feed.dart';
import 'grid.dart';
import 'media.dart';
import 'theme.dart';

/// Albums are shared by everyone who uses the Snapshots PC.
class AlbumsScreen extends StatefulWidget {
  const AlbumsScreen({super.key});

  @override
  State<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends State<AlbumsScreen> {
  List<Album>? _albums;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await apiOf(context).get('/api/albums');
      if (!mounted) return;
      setState(() {
        _albums = [for (final j in r['albums'] as List) Album(Map<String, dynamic>.from(j as Map))];
        _error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _create() async {
    final name = await askText(context, 'New album', label: 'Name', ok: 'Create');
    if (name == null || !mounted) return;
    try {
      await apiOf(context).post('/api/albums', {'name': name});
      await _load();
      if (mounted) showMessage(context, 'Album made. Select photos and choose "Add to album" to fill it.');
    } on ApiError catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _open(Album a) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AlbumScreen(album: a)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final albums = _albums;
    return Scaffold(
      appBar: AppBar(title: const Text('Albums'), actions: [
        IconButton(tooltip: 'New album', icon: const Icon(Icons.add), onPressed: _create),
      ]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: albums == null
            ? ListView(children: [
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(child: _error != null ? Text(_error!, textAlign: TextAlign.center) : const CircularProgressIndicator()),
                ),
              ])
            : albums.isEmpty
                ? ListView(children: const [
                    Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('No albums yet. Tap + to make one.', textAlign: TextAlign.center),
                    ),
                  ])
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 200,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: .78,
                    ),
                    itemCount: albums.length,
                    itemBuilder: (context, i) => CoverTile(
                      path: albums[i].coverPath,
                      title: albums[i].name,
                      subtitle: albums[i].smart ? 'Smart album · ${albums[i].count}' : '${albums[i].count} items',
                      icon: Icons.photo_album_outlined,
                      onTap: () => _open(albums[i]),
                    ),
                  ),
      ),
    );
  }
}

/// A square cover with a title and a line under it (albums, places, tags…).
class CoverTile extends StatelessWidget {
  const CoverTile({super.key, required this.path, required this.title, this.subtitle, this.onTap, this.icon = Icons.image_outlined});

  final String? path;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox.expand(child: ServerThumb(path, icon: icon)))),
        const SizedBox(height: 6),
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
        if (subtitle != null)
          Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class AlbumScreen extends StatefulWidget {
  const AlbumScreen({super.key, required this.album});

  final Album album;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  late Album _album = widget.album;
  late final Feed _feed = Feed(apiOf(context), {'album': widget.album.id});

  Future<void> _rename() async {
    final name = await askText(context, 'Rename album', initial: _album.name, label: 'Name');
    if (name == null || !mounted) return;
    try {
      final r = await apiOf(context).patch('/api/albums/${_album.id}', {'name': name});
      if (mounted) setState(() => _album = Album(Map<String, dynamic>.from(r as Map)));
    } on ApiError catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _delete() async {
    final ok = await confirm(context, 'Delete "${_album.name}"?',
        'The album goes away for everyone. The photos in it stay in Snapshots.',
        ok: 'Delete album', danger: true);
    if (!ok || !mounted) return;
    try {
      await apiOf(context).delete('/api/albums/${_album.id}');
      if (mounted) Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _album;
    final range = a.first != null && a.last != null ? _range(a.first!, a.last!) : null;
    return GridScreen(
      title: a.name,
      feed: _feed,
      mode: a.smart ? GridMode.library : GridMode.album,
      albumId: a.id,
      emptyText: a.smart ? 'Nothing matches this smart album yet.' : 'This album is empty. Select photos anywhere and choose "Add to album".',
      header: range == null && a.ruleText == null
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Text([?range, if (a.smart && a.ruleText != null) a.ruleText!].join(' · '),
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
      actions: [
        PopupMenuButton<String>(
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'delete', child: Text('Delete album')),
          ],
          onSelected: (v) => v == 'rename' ? _rename() : _delete(),
        ),
      ],
    );
  }

  static String _range(DateTime a, DateTime b) {
    final f = DateFormat.yMMMd();
    final x = f.format(a), y = f.format(b);
    return x == y ? x : '$x – $y';
  }
}
