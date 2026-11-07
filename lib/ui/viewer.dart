import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:photo_view/photo_view.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/feed.dart';
import '../state/session.dart';
import 'actions.dart';
import 'comments.dart';
import 'details.dart';
import 'editor.dart';
import 'grid.dart';
import 'media.dart';
import 'theme.dart';

/// Full-screen photos and videos. Swipe for the next one; tap to show or hide the controls.
class Viewer extends StatefulWidget {
  const Viewer({super.key, required this.feed, required this.index, this.mode = GridMode.library, this.albumId});

  final Feed feed;
  final int index;
  final GridMode mode;
  final int? albumId;

  @override
  State<Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<Viewer> {
  late final PageController _pages;
  late int _index;
  bool _chrome = true;
  bool _live = false;

  Feed get feed => widget.feed;

  /// The locked folder's photos are not kept on the phone.
  bool get _cache => widget.mode != GridMode.locked;
  Asset? get current => _index < feed.items.length ? feed.items[_index] : null;

  @override
  void initState() {
    super.initState();
    _index = widget.index;
    _pages = PageController(initialPage: _index);
    feed.addListener(_changed);
  }

  @override
  void dispose() {
    feed.removeListener(_changed);
    _pages.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (feed.items.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    if (_index >= feed.items.length) _index = feed.items.length - 1;
    setState(() {});
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    SystemChrome.setEnabledSystemUIMode(_chrome ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
  }

  Future<void> _do(Future<bool> Function(AssetActions a, List<Asset> one) job, {bool removes = false}) async {
    final a = current;
    if (a == null) return;
    final ok = await job(AssetActions(context), [a]);
    if (!mounted) return;
    if (ok && removes) {
      feed.remove([a.id]);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = current;
    final api = apiOf(context);
    return Theme(
      data: buildTheme(Brightness.dark),
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: _chrome && a != null ? _topBar(a) : null,
        body: Stack(children: [
          PhotoViewGestureDetectorScope(
            axis: Axis.horizontal,
            child: PageView.builder(
            controller: _pages,
            itemCount: feed.items.length,
            onPageChanged: (i) {
              setState(() {
                _index = i;
                _live = false;
              });
              if (i >= feed.items.length - 5) feed.loadMore();
            },
            itemBuilder: (context, i) {
              final item = feed.items[i];
              if (item.isVideo) {
                return _VideoPage(key: ValueKey('v${item.id}'), api: api, asset: item, active: i == _index, onTap: _toggleChrome, chrome: _chrome, cache: _cache);
              }
              if (item.live && _live && i == _index) {
                return _VideoPage(key: ValueKey('m${item.id}'), api: api, asset: item, active: true, motion: true, onTap: () => setState(() => _live = false), chrome: false, cache: _cache);
              }
              return _PhotoPage(
                key: ValueKey('p${item.id}'),
                api: api,
                asset: item,
                cache: _cache,
                onTap: _toggleChrome,
              );
            },
          )),
          if (_chrome && a != null) Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar(a)),
        ]),
      ),
    );
  }

  PreferredSizeWidget _topBar(Asset a) {
    final fmt = DateFormat.yMMMd().add_jm();
    return AppBar(
      backgroundColor: Colors.black54,
      foregroundColor: Colors.white,
      title: Text(fmt.format(a.takenAt), style: const TextStyle(fontSize: 16)),
      actions: [
        if (a.live && !a.isVideo)
          IconButton(
            tooltip: _live ? 'Stop' : 'Play the moving part',
            icon: Icon(_live ? Icons.motion_photos_pause_outlined : Icons.motion_photos_on_outlined),
            onPressed: () => setState(() => _live = !_live),
          ),
        IconButton(tooltip: 'Details', icon: const Icon(Icons.info_outline), onPressed: () => _info(a)),
        PopupMenuButton<String>(
          itemBuilder: (_) => [
            if (widget.mode != GridMode.trash && widget.mode != GridMode.locked)
              const PopupMenuItem(value: 'album', child: Text('Add to album')),
            if (widget.mode == GridMode.album) const PopupMenuItem(value: 'unalbum', child: Text('Remove from album')),
            if (widget.mode != GridMode.trash && widget.mode != GridMode.locked)
              const PopupMenuItem(value: 'save', child: Text('Save to phone')),
            if (widget.mode == GridMode.library || widget.mode == GridMode.album)
              PopupMenuItem(value: 'archive', child: Text(a.archived ? 'Unarchive' : 'Archive')),
            if (widget.mode == GridMode.archive) const PopupMenuItem(value: 'unarchive', child: Text('Unarchive')),
            if (_editable) ...[
              const PopupMenuDivider(),
              if (!a.isVideo) const PopupMenuItem(value: 'edit', child: Text('Edit')),
              const PopupMenuItem(value: 'marks', child: Text('Stars and label')),
              const PopupMenuItem(value: 'date', child: Text('Change date')),
              const PopupMenuItem(value: 'place', child: Text('Change location')),
              const PopupMenuItem(value: 'comments', child: Text('Comments')),
            ],
          ],
          onSelected: (v) => switch (v) {
            'album' => _do((x, one) => x.addToAlbum(one)),
            'unalbum' => _do((x, one) => x.removeFromAlbum(widget.albumId!, one), removes: true),
            'save' => _do((x, one) async {
                await x.saveToPhone(one);
                return true;
              }),
            'archive' => _do((x, one) => x.archive(one, !a.archived), removes: !a.archived && widget.mode == GridMode.library),
            'unarchive' => _do((x, one) => x.archive(one, false), removes: true),
            'edit' => _edit(a),
            'marks' => _do((x, one) => editMarks(context, one)),
            'date' => _do((x, one) => changeDate(context, one)),
            'place' => _do((x, one) => changePlace(context, one)),
            'comments' => showComments(context, assetId: a.id),
            _ => null,
          },
        ),
      ],
    );
  }

  /// Not in the trash or the locked folder: there photos can't be edited, marked or commented on.
  bool get _editable => widget.mode != GridMode.trash && widget.mode != GridMode.locked;

  Future<void> _edit(Asset a) async {
    final edited = await Navigator.of(context).push<Asset>(MaterialPageRoute(builder: (_) => EditorScreen(asset: a)));
    if (edited == null || !mounted) return;
    final i = feed.items.indexWhere((x) => x.id == a.id);
    if (i >= 0) {
      // The new version (v) makes the grid and the viewer load the edited picture.
      edited.favorite = a.favorite;
      feed.items[i] = edited;
      feed.changed();
    }
    showMessage(context, edited.edited ? 'Saved. Your original file is unchanged.' : 'Back to the original.');
  }

  Widget _bottomBar(Asset a) {
    final buttons = <Widget>[
      if (widget.mode == GridMode.trash) ...[
        _BarButton(icon: Icons.restore, label: 'Restore', onTap: () => _do((x, one) => x.restore(one), removes: true)),
        if (context.read<Session>().user?.isAdmin == true)
          _BarButton(icon: Icons.delete_forever_outlined, label: 'Delete', onTap: () => _do((x, one) => x.deleteForever(one), removes: true)),
      ] else ...[
        _BarButton(icon: Icons.share_outlined, label: 'Share', onTap: () => _do((x, one) async {
              await x.share(one, keep: _cache);
              return true;
            })),
        if (widget.mode != GridMode.locked)
          _BarButton(
            icon: a.favorite ? Icons.favorite : Icons.favorite_border,
            label: 'Favourite',
            color: a.favorite ? heart : null,
            onTap: () => _do((x, one) => x.favorite(one, !a.favorite), removes: false),
          ),
        if (widget.mode != GridMode.locked)
          _BarButton(icon: Icons.delete_outline, label: 'Trash', onTap: () => _do((x, one) => x.trash(one), removes: true)),
      ],
    ];
    return Container(
      color: Colors.black54,
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom, top: 4),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: buttons),
    );
  }

  Future<void> _info(Asset a) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .55,
        maxChildSize: .92,
        builder: (c, scroll) => InfoSheet(asset: a, scroll: scroll, cache: _cache, editable: _editable),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.label, required this.onTap, this.color});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: color ?? Colors.white),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ]),
        ),
      );
}

class _PhotoPage extends StatelessWidget {
  const _PhotoPage({super.key, required this.api, required this.asset, required this.onTap, this.cache = true});

  final bool cache;

  final Api api;
  final Asset asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Big originals (50 MP and more) are decoded at most 3000 px wide, which is plenty to zoom on a phone.
    final full = ResizeImage(serverImage(api, asset.viewPath(), cache: cache), width: 3000, height: 3000, policy: ResizeImagePolicy.fit, allowUpscaling: false);
    return PhotoView(
      imageProvider: full,
      backgroundDecoration: const BoxDecoration(color: Colors.black),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 4,
      onTapUp: (_, _, _) => onTap(),
      loadingBuilder: (context, event) => Stack(fit: StackFit.expand, children: [
        if (asset.hasThumb) Image(image: serverImage(api, asset.thumbPath(), cache: cache), fit: BoxFit.contain, gaplessPlayback: true),
        const Center(child: CircularProgressIndicator()),
      ]),
      errorBuilder: (context, error, stack) => Stack(fit: StackFit.expand, children: [
        if (asset.hasThumb) Image(image: serverImage(api, asset.thumbPath(), cache: cache), fit: BoxFit.contain),
        const Align(
          alignment: Alignment(0, .7),
          child: Text("Couldn't load the full photo.", style: TextStyle(color: Colors.white70)),
        ),
      ]),
    );
  }
}

/// A video (or the moving part of a Live Photo). Played straight from the server; Android plays
/// HEVC itself, so the server only converts a video when the phone can't play it.
class _VideoPage extends StatefulWidget {
  const _VideoPage({
    super.key,
    required this.api,
    required this.asset,
    required this.active,
    required this.onTap,
    required this.chrome,
    this.motion = false,
    this.cache = true,
  });

  final Api api;
  final Asset asset;
  final bool active;
  final bool motion;
  final bool chrome;
  final bool cache;
  final VoidCallback onTap;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _player;
  String? _error;
  String? _status;
  bool _converted = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(_VideoPage old) {
    super.didUpdateWidget(old);
    if (widget.active && _player == null && _error == null && _poll == null) _start();
    if (!widget.active) _player?.pause();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _start({bool convert = false}) async {
    try {
      String path;
      if (widget.motion) {
        path = widget.asset.motionPath();
      } else {
        final r = await widget.api.get('/api/assets/${widget.asset.id}/play', query: {'convert': convert ? 'true' : 'false'});
        if (!mounted) return;
        if (r['error'] is String) throw ApiError(r['error'] as String);
        if (r['preparing'] == true) {
          setState(() => _status = 'Snapshots is converting this video so the phone can play it… ${((r['progress'] as num? ?? 0) * 100).round()}%');
          _poll = Timer(const Duration(milliseconds: 1500), () {
            _poll = null;
            if (mounted) _start(convert: true);
          });
          return;
        }
        path = r['url'] as String;
        _converted = r['converted'] == true;
      }
      final p = VideoPlayerController.networkUrl(Uri.parse(widget.api.url(path)), httpHeaders: widget.api.authHeaders);
      _player = p;
      await p.initialize();
      if (!mounted) return;
      await p.setLooping(widget.motion);
      if (widget.active) await p.play();
      setState(() => _status = null);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      // The phone couldn't play it: ask Snapshots for a copy it can play.
      await _player?.dispose();
      _player = null;
      if (!convert && !_converted && !widget.motion && mounted) {
        setState(() => _status = 'Preparing…');
        return _start(convert: true);
      }
      if (mounted) setState(() => _error = "This video can't be played on the phone.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _player;
    Widget body;
    if (_error != null) {
      body = Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center)));
    } else if (p == null || !p.value.isInitialized) {
      body = Stack(fit: StackFit.expand, children: [
        if (widget.asset.hasThumb) Image(image: serverImage(widget.api, widget.asset.thumbPath(), cache: widget.cache), fit: BoxFit.contain),
        Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            if (_status != null) Padding(padding: const EdgeInsets.all(16), child: Text(_status!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center)),
          ]),
        ),
      ]);
    } else {
      body = Stack(children: [
        Center(child: AspectRatio(aspectRatio: p.value.aspectRatio, child: VideoPlayer(p))),
        if (!widget.motion && widget.chrome)
          Positioned(
            left: 12,
            right: 12,
            bottom: MediaQuery.paddingOf(context).bottom + 76,
            child: _Controls(player: p),
          ),
      ]);
    }
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: ColoredBox(color: Colors.black, child: body));
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.player});

  final VideoPlayerController player;

  String _t(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}' : '$m:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, v, _) => Row(children: [
        IconButton(
          color: Colors.white,
          icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
          onPressed: () => v.isPlaying ? player.pause() : player.play(),
        ),
        Text(_t(v.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
        const SizedBox(width: 8),
        Expanded(
          child: VideoProgressIndicator(player, allowScrubbing: true, padding: const EdgeInsets.symmetric(vertical: 12)),
        ),
        const SizedBox(width: 8),
        Text(_t(v.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
      ]),
    );
  }
}

/// Details about one photo: date, place, camera, people, albums…
class InfoSheet extends StatefulWidget {
  const InfoSheet({super.key, required this.asset, required this.scroll, this.cache = true, this.editable = false});

  final Asset asset;
  final ScrollController scroll;

  /// Offer to change the date, place, description and marks, and to read and write comments.
  final bool editable;

  /// False in the locked folder: nothing from it is kept on the phone.
  final bool cache;

  @override
  State<InfoSheet> createState() => _InfoSheetState();
}

class _InfoSheetState extends State<InfoSheet> {
  AssetDetail? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await apiOf(context).get('/api/assets/${widget.asset.id}');
      if (mounted) setState(() => _d = AssetDetail(Map<String, dynamic>.from(r as Map)));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  static String _size(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(b / 1024).ceil()} KB';
  }

  @override
  Widget build(BuildContext context) {
    final a = _d?.asset ?? widget.asset;
    final d = _d;
    final t = Theme.of(context);
    Widget row(IconData icon, String title, [String? sub]) => ListTile(
          dense: true,
          leading: Icon(icon),
          title: Text(title),
          subtitle: sub == null ? null : Text(sub),
        );
    final edit = widget.editable && d != null;
    Widget tap(IconData icon, String title, String? sub, VoidCallback? onTap, {IconData trailing = Icons.edit_outlined}) => ListTile(
          dense: true,
          leading: Icon(icon),
          title: Text(title),
          subtitle: sub == null ? null : Text(sub),
          trailing: onTap == null ? null : Icon(trailing, size: 18),
          onTap: onTap,
        );
    Future<void> then(Future<bool> job) async {
      if (await job && mounted) _load();
    }

    final marks = [
      if (a.rating > 0) a.rating == 1 ? '1 star' : '${a.rating} stars',
      if (a.label != null) labelName(a.label!),
      if (a.flag == 1) 'Picked',
      if (a.flag == -1) 'Rejected',
    ];
    final place = a.place != null && a.place!.label.isNotEmpty ? a.place!.label : (d?.position != null ? 'On the map' : null);
    return ListView(controller: widget.scroll, padding: const EdgeInsets.only(bottom: 24), children: [
      tap(Icons.event, DateFormat.yMMMMEEEEd().add_jm().format(a.takenAt), null,
          edit ? () => then(changeDate(context, [widget.asset])) : null),
      row(a.isVideo ? Icons.movie_outlined : Icons.image_outlined, a.filename,
          [if (a.width != null && a.height != null) '${a.width} × ${a.height}', _size(a.size), if (a.edited) 'edited'].join(' · ')),
      if (a.camera != null) row(Icons.photo_camera_outlined, a.camera!),
      if (place != null || edit)
        tap(Icons.place_outlined, place ?? 'No location', null, edit ? () => then(changePlace(context, [widget.asset])) : null),
      if (d?.folder != null) row(Icons.folder_outlined, d!.folder!.isEmpty ? 'Library folder' : d.folder!),
      if (edit)
        tap(Icons.notes, (d.description ?? '').isEmpty ? 'Add a description' : d.description!, null,
            () => then(changeDescription(context, widget.asset, d.description)))
      else if (d?.description != null && d!.description!.isNotEmpty)
        row(Icons.notes, d.description!),
      if (edit || marks.isNotEmpty)
        tap(Icons.star_outline, marks.isEmpty ? 'No stars or label' : marks.join(' · '), null,
            edit ? () => then(editMarks(context, [widget.asset])) : null),
      if (edit)
        tap(Icons.chat_bubble_outline, d.comments == 0 ? 'Comments' : d.comments == 1 ? '1 comment' : '${d.comments} comments', null,
            () async {
          await showComments(context, assetId: a.id);
          if (mounted) _load();
        }, trailing: Icons.chevron_right),
      if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
      if (d == null && _error == null) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
      if (d != null && d.people.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('People', style: t.textTheme.titleSmall)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in d.people)
              ActionChip(
                avatar: CircleAvatar(backgroundImage: serverImage(apiOf(context), '/api/faces/${p.faceId}/thumb', cache: widget.cache)),
                label: Text(p.name ?? 'Not named yet'),
                onPressed: () => openGrid(context, p.name ?? 'Not named yet', {'person': p.personId, 'archived': 'hide', 'stacks': true}),
              ),
          ]),
        ),
      ],
      if (d != null && d.albums.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Albums', style: t.textTheme.titleSmall)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final al in d.albums)
              ActionChip(
                avatar: const Icon(Icons.photo_album_outlined, size: 18),
                label: Text(al.name),
                onPressed: () => openGrid(context, al.name, {'album': al.id}, mode: GridMode.album, albumId: al.id),
              ),
          ]),
        ),
      ],
      if (d != null && d.tags.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Tags', style: t.textTheme.titleSmall)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final tg in d.tags)
              ActionChip(label: Text(tg.name), onPressed: () => openGrid(context, tg.name, {'tag': tg.id})),
          ]),
        ),
      ],
      if (d?.text != null && d!.text!.trim().isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Text in the photo', style: t.textTheme.titleSmall)),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: SelectableText(d.text!.trim())),
      ],
    ]);
  }
}
