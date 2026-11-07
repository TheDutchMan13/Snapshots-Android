import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/feed.dart';
import '../state/session.dart';
import 'actions.dart';
import 'details.dart';
import 'filter_sheet.dart';
import 'media.dart';
import 'slideshow.dart';
import 'viewer.dart';

/// What the selection bar offers: it depends on where the photos are.
enum GridMode { library, archive, trash, album, locked }

/// A screen with a grid of photos: the timeline, an album, a person, a search result…
class GridScreen extends StatefulWidget {
  const GridScreen({
    super.key,
    required this.title,
    required this.feed,
    this.mode = GridMode.library,
    this.albumId,
    this.months = false,
    this.actions = const [],
    this.header,
    this.emptyText = 'Nothing here yet.',
    this.showAppBar = true,
    this.ownsFeed = true,
    this.filterable = false,
    this.slideshow = true,
    this.menu = const [],
  });

  final String title;
  final Feed feed;
  final GridMode mode;
  final int? albumId;

  /// Month headings (the timeline).
  final bool months;
  final List<Widget> actions;
  final Widget? header;
  final String emptyText;
  final bool showAppBar;

  /// Dispose the feed with the screen.
  final bool ownsFeed;

  /// A Filter button (stars, size, camera…) in the bar.
  final bool filterable;

  /// "Slideshow" in the bar's menu.
  final bool slideshow;

  /// More entries for that menu (an album's Rename, Delete…): a label and what it does.
  final List<(String, VoidCallback)> menu;

  @override
  State<GridScreen> createState() => GridScreenState();
}

class GridScreenState extends State<GridScreen> {
  final selected = <int>{};
  final _scroll = ScrollController();

  bool get selecting => selected.isNotEmpty;
  Feed get feed => widget.feed;

  @override
  void initState() {
    super.initState();
    feed.addListener(_changed);
    if (feed.items.isEmpty && !feed.done) feed.loadMore();
  }

  @override
  void didUpdateWidget(GridScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feed != widget.feed) {
      oldWidget.feed.removeListener(_changed);
      widget.feed.addListener(_changed);
      selected.clear();
      if (widget.feed.items.isEmpty && !widget.feed.done) widget.feed.loadMore();
    }
  }

  @override
  void dispose() {
    feed.removeListener(_changed);
    if (widget.ownsFeed) feed.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final ids = {for (final a in feed.items) a.id};
    selected.removeWhere((id) => !ids.contains(id));
    setState(() {});
  }

  void scrollToTop() {
    if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  void _tap(int index) {
    final a = feed.items[index];
    if (selecting) {
      setState(() => selected.contains(a.id) ? selected.remove(a.id) : selected.add(a.id));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Viewer(feed: feed, index: index, mode: widget.mode, albumId: widget.albumId),
    ));
  }

  void _long(int index) => setState(() => selected.add(feed.items[index].id));

  List<Asset> get _picked => [for (final a in feed.items) if (selected.contains(a.id)) a];

  Future<void> _act(Future<bool> Function(AssetActions a, List<Asset> items) job, {bool removes = false, bool refresh = false}) async {
    final items = _picked;
    final ok = await job(AssetActions(context), items);
    if (!mounted) return;
    if (ok && removes) feed.remove(items.map((a) => a.id));
    setState(() => selected.clear());
    // A new date moves photos in the timeline: show it again from the top.
    if (ok && refresh) feed.refresh();
  }

  List<Widget> _selectionActions() {
    final m = widget.mode;
    final isAdmin = context.read<Session>().user?.isAdmin == true;
    final all = _picked;
    final anyNotFav = all.any((a) => !a.favorite);
    final more = <PopupMenuEntry<String>>[
      if (m != GridMode.trash && m != GridMode.locked) const PopupMenuItem(value: 'album', child: Text('Add to album')),
      if (m == GridMode.album) const PopupMenuItem(value: 'unalbum', child: Text('Remove from album')),
      if (m != GridMode.trash && m != GridMode.locked) const PopupMenuItem(value: 'save', child: Text('Save to phone')),
      if (m != GridMode.trash && m != GridMode.locked) ...const [
        PopupMenuItem(value: 'marks', child: Text('Stars and label')),
        PopupMenuItem(value: 'date', child: Text('Change date')),
        PopupMenuItem(value: 'place', child: Text('Change location')),
      ],
      if (m == GridMode.library || m == GridMode.album) const PopupMenuItem(value: 'archive', child: Text('Archive')),
      if (m == GridMode.archive) const PopupMenuItem(value: 'unarchive', child: Text('Unarchive')),
      if (m != GridMode.trash && m != GridMode.locked) const PopupMenuItem(value: 'trash', child: Text('Move to trash')),
      if (m == GridMode.trash && isAdmin) const PopupMenuItem(value: 'delete', child: Text('Delete for good')),
    ];
    return [
      if (m == GridMode.trash)
        IconButton(
          tooltip: 'Restore',
          icon: const Icon(Icons.restore),
          onPressed: () => _act((a, i) => a.restore(i), removes: true),
        )
      else ...[
        IconButton(tooltip: 'Share', icon: const Icon(Icons.share_outlined), onPressed: () => _act((a, i) async {
              await a.share(i, keep: m != GridMode.locked);
              return true;
            })),
        if (m != GridMode.locked)
          IconButton(
            tooltip: anyNotFav ? 'Favourite' : 'Remove from favourites',
            icon: Icon(anyNotFav ? Icons.favorite_border : Icons.favorite),
            onPressed: () => _act((a, i) => a.favorite(i, anyNotFav)),
          ),
      ],
      if (more.isNotEmpty)
        PopupMenuButton<String>(
          itemBuilder: (_) => more,
          onSelected: (v) => switch (v) {
            'album' => _act((a, i) => a.addToAlbum(i)),
            'unalbum' => _act((a, i) => a.removeFromAlbum(widget.albumId!, i), removes: true),
            'save' => _act((a, i) async {
                await a.saveToPhone(i);
                return true;
              }),
            'marks' => _act((a, i) => editMarks(context, i)),
            'date' => _act((a, i) => changeDate(context, i), refresh: true),
            'place' => _act((a, i) => changePlace(context, i), refresh: true),
            'archive' => _act((a, i) => a.archive(i, true), removes: true),
            'unarchive' => _act((a, i) => a.archive(i, false), removes: true),
            'trash' => _act((a, i) => a.trash(i), removes: true),
            'delete' => _act((a, i) => a.deleteForever(i), removes: true),
            _ => null,
          },
        ),
    ];
  }

  PreferredSizeWidget? _appBar() {
    if (selecting) {
      return AppBar(
        leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Done', onPressed: () => setState(selected.clear)),
        title: Text('${selected.length} selected'),
        actions: [
          IconButton(
            tooltip: 'Select all loaded',
            icon: const Icon(Icons.select_all),
            onPressed: () => setState(() => selected.addAll(feed.items.map((a) => a.id))),
          ),
          ..._selectionActions(),
        ],
      );
    }
    if (!widget.showAppBar) return null;
    return AppBar(title: Text(widget.title), actions: [
      if (widget.filterable) FilterButton(feed: feed),
      ...widget.actions,
      if (widget.slideshow || widget.menu.isNotEmpty)
        PopupMenuButton<VoidCallback>(
          itemBuilder: (_) => [
            if (widget.slideshow) PopupMenuItem(value: openSlideshow, child: const Text('Slideshow')),
            for (final (label, run) in widget.menu) PopupMenuItem(value: run, child: Text(label)),
          ],
          onSelected: (run) => run(),
        ),
    ]);
  }

  void openSlideshow() {
    if (feed.items.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Slideshow(feed: feed, cache: widget.mode != GridMode.locked),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // A grid on a hidden tab never holds on to Back.
      canPop: !selecting || !TickerMode.valuesOf(context).enabled,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(selected.clear);
      },
      child: Scaffold(
        appBar: _appBar(),
        body: RefreshIndicator(
          onRefresh: feed.refresh,
          child: AssetGridView(
            feed: feed,
            controller: _scroll,
            months: widget.months,
            selected: selected,
            selecting: selecting,
            onTap: _tap,
            onLongPress: _long,
            header: widget.header,
            emptyText: widget.emptyText,
            cacheThumbs: widget.mode != GridMode.locked,
          ),
        ),
      ),
    );
  }
}

/// The scrolling grid itself, with month headings when asked, loading more near the end.
class AssetGridView extends StatelessWidget {
  const AssetGridView({
    super.key,
    required this.feed,
    required this.controller,
    required this.onTap,
    required this.onLongPress,
    this.selected = const {},
    this.selecting = false,
    this.months = false,
    this.header,
    this.emptyText = 'Nothing here yet.',
    this.cacheThumbs = true,
  });

  final Feed feed;
  final ScrollController controller;
  /// False for the locked folder: its photos are not kept on the phone.
  final bool cacheThumbs;
  final void Function(int index) onTap;
  final void Function(int index) onLongPress;
  final Set<int> selected;
  final bool selecting;
  final bool months;
  final Widget? header;
  final String emptyText;

  static final _monthFmt = DateFormat.yMMMM();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = math.max(4, (c.maxWidth / 100).floor());
      final rows = _rows(cols);
      final t = Theme.of(context);
      final slivers = <Widget>[
        if (header != null) SliverToBoxAdapter(child: header),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              if (i >= rows.length - 30 && !feed.done && !feed.loading && feed.error == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) => feed.loadMore());
              }
              final r = rows[i];
              if (r.month != null) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(14, 18, 14, 8),
                  child: Text(r.month!, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(children: [
                  for (var k = 0; k < cols; k++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: k < cols - 1 ? 2 : 0),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: k < r.indexes.length ? _tile(context, r.indexes[k]) : const SizedBox(),
                        ),
                      ),
                    ),
                ]),
              );
            },
            childCount: rows.length,
          ),
        ),
        SliverToBoxAdapter(child: _footer(context)),
      ];
      return Scrollbar(
        controller: controller,
        interactive: true,
        thickness: 6,
        radius: const Radius.circular(3),
        child: CustomScrollView(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: slivers,
        ),
      );
    });
  }

  Widget _footer(BuildContext context) {
    if (feed.error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Text(feed.error!, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: feed.items.isEmpty ? feed.refresh : feed.loadMore, child: const Text('Try again')),
        ]),
      );
    }
    if (feed.loading || !feed.done) {
      return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    if (feed.items.isEmpty) {
      return Padding(padding: const EdgeInsets.fromLTRB(24, 64, 24, 24), child: Text(emptyText, textAlign: TextAlign.center));
    }
    return const SizedBox(height: 96);
  }

  List<_Row> _rows(int cols) {
    final rows = <_Row>[];
    String? month;
    var current = <int>[];
    void flush() {
      if (current.isNotEmpty) rows.add(_Row(indexes: current));
      current = <int>[];
    }

    for (var i = 0; i < feed.items.length; i++) {
      final a = feed.items[i];
      if (months && a.monthKey != month) {
        flush();
        month = a.monthKey;
        rows.add(_Row(month: _monthFmt.format(a.takenAt)));
      }
      current.add(i);
      if (current.length == cols) flush();
    }
    flush();
    return rows;
  }

  Widget _tile(BuildContext context, int index) {
    final a = feed.items[index];
    final on = selected.contains(a.id);
    final t = Theme.of(context);
    return GestureDetector(
      onTap: () => onTap(index),
      onLongPress: () => onLongPress(index),
      child: Stack(fit: StackFit.expand, children: [
        AnimatedScale(
          duration: const Duration(milliseconds: 120),
          scale: on ? .84 : 1,
          child: ServerThumb(a.hasThumb ? a.thumbPath() : null, cache: cacheThumbs, icon: a.isVideo ? Icons.movie_outlined : Icons.image_outlined),
        ),
        if (a.isVideo)
          const Positioned(right: 4, top: 4, child: Icon(Icons.play_circle_fill, color: Colors.white, size: 20, shadows: [Shadow(blurRadius: 4)])),
        Positioned(
          left: 4,
          bottom: 4,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (a.favorite) const Icon(Icons.favorite, color: Colors.white, size: 16, shadows: [Shadow(blurRadius: 4)]),
            if (a.favorite) const SizedBox(width: 3),
            MarksBadge(asset: a),
          ]),
        ),
        if (a.stackCount > 1)
          const Positioned(right: 4, bottom: 4, child: Icon(Icons.layers, color: Colors.white, size: 16, shadows: [Shadow(blurRadius: 4)])),
        if (selecting)
          Positioned(
            left: 4,
            top: 4,
            child: Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
                color: on ? t.colorScheme.primary : Colors.white, size: 22, shadows: const [Shadow(blurRadius: 4)]),
          ),
      ]),
    );
  }
}

class _Row {
  _Row({this.month, this.indexes = const []});

  final String? month;
  final List<int> indexes;
}

/// Opens a grid screen for a filter.
void openGrid(BuildContext context, String title, Map<String, dynamic> query,
    {GridMode mode = GridMode.library, int? albumId, List<Widget> actions = const [], String? empty, bool filterable = true}) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (c) => GridScreen(
      title: title,
      feed: Feed(apiOf(c), query),
      mode: mode,
      albumId: albumId,
      actions: actions,
      emptyText: empty ?? 'Nothing here yet.',
      filterable: filterable,
    ),
  ));
}
