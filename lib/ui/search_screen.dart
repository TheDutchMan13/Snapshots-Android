import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/feed.dart';
import 'albums_screen.dart';
import 'grid.dart';
import 'media.dart' show apiOf;

/// Search by words, names, places and dates, or by what's in the photo. With nothing typed,
/// it shows places, trips and tags to browse.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _box = TextEditingController();
  String _q = '';

  /// How results are ranked: 'mix' (words and content together), 'words', or 'look' (content).
  String _mode = 'words';
  Map<String, dynamic>? _counts;
  Feed? _feed;
  int _gen = 0;

  @override
  void dispose() {
    _box.dispose();
    super.dispose();
  }

  Future<void> _search(String text) async {
    final q = text.trim();
    final gen = ++_gen;
    setState(() {
      _q = q;
      _counts = null;
      _feed = q.isEmpty ? null : _newFeed(q, _mode);
    });
    if (q.isEmpty) return;
    try {
      final r = await apiOf(context).get('/api/search', query: {'q': q});
      if (!mounted || gen != _gen) return;
      final counts = Map<String, dynamic>.from(r as Map);
      setState(() => _counts = counts);
      final words = (counts['words'] as int?) ?? 0, content = (counts['content'] as int?) ?? 0;
      if (counts['mixed'] != null && words > 0 && content > 0) {
        _setMode('mix');
      } else if (words == 0 && content > 0) {
        _setMode('look'); // nothing by words, but something by content: show that instead
      } else if (_mode != 'words') {
        _setMode('words');
      }
    } on ApiError {
      // The grid shows the error.
    }
  }

  Feed _newFeed(String q, String mode) =>
      Feed(apiOf(context), {'q': q, if (mode == 'look') 'look': true, if (mode == 'mix') 'mix': true});

  void _setMode(String mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      if (_q.isNotEmpty) _feed = _newFeed(_q, mode);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _counts;
    final contentOn = c != null && c['content_enabled'] == true;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: TextField(
          controller: _box,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: 'Search names, places, dates, things…',
            border: InputBorder.none,
            suffixIcon: _q.isEmpty && _box.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _box.clear();
                      _search('');
                    },
                  ),
          ),
        ),
      ),
      body: _feed == null
          ? const _Explore()
          : Column(children: [
              if (contentOn)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: [
                        if (c['mixed'] != null && (c['words'] as int? ?? 0) > 0)
                          ButtonSegment(value: 'mix', label: Text('Best (${c['mixed']})')),
                        ButtonSegment(value: 'words', label: Text('Words (${c['words']})')),
                        ButtonSegment(value: 'look', label: Text("What's in it (${c['content']})")),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (s) => _setMode(s.first),
                    ),
                  ),
                ),
              if (_mode == 'look' && c != null && c['content_ready'] != true)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text('Search by what is in the photo is still getting ready on the PC.'),
                ),
              Expanded(
                child: GridScreen(
                  key: ValueKey(_feed),
                  title: _q,
                  feed: _feed!,
                  showAppBar: false,
                  emptyText: 'Nothing found for "$_q".',
                ),
              ),
            ]),
    );
  }
}

class _Explore extends StatefulWidget {
  const _Explore();

  @override
  State<_Explore> createState() => _ExploreState();
}

class _ExploreState extends State<_Explore> {
  List<Cover>? _places, _trips, _tags;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = apiOf(context);
    try {
      final rs = await Future.wait([api.get('/api/places'), api.get('/api/events'), api.get('/api/tags')]);
      if (!mounted) return;
      final dates = DateFormat.yMMMd();
      setState(() {
        _places = [for (final p in rs[0]['places'] as List) placeCover(Map<String, dynamic>.from(p as Map))];
        _trips = [
          for (final e in rs[1]['events'] as List)
            if (e['kind'] == 'trip')
              Cover(
                title: (e['place'] as String?) ?? 'Trip',
                subtitle: '${dates.format(DateTime.parse(e['start'] as String))} · ${e['days']} days',
                cover: e['cover'] as int?,
                coverV: (e['cover_v'] as String?) ?? '',
                query: {'start': e['start'], 'end': e['end'], 'archived': 'hide'},
              ),
        ];
        _tags = [
          for (final t in rs[2]['tags'] as List)
            Cover(
              title: t['name'] as String,
              subtitle: '${t['count']} items',
              cover: t['cover'] as int?,
              coverV: (t['cover_v'] as String?) ?? '',
              query: {'tag': t['id']},
            ),
        ];
        _error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_places == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () {
                      setState(() => _error = null);
                      _load();
                    },
                    child: const Text('Try again'),
                  ),
                ]),
              ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: [
        _Strip(title: 'Places', items: _places!, onAll: () => _all('Places', _places!)),
        _Strip(title: 'Trips', items: _trips!, onAll: () => _all('Trips', _trips!)),
        _Strip(title: 'Tags', items: _tags!, onAll: () => _all('Tags', _tags!)),
        if (_places!.isEmpty && _trips!.isEmpty && _tags!.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text('Places, trips and tags show up here as Snapshots learns about your photos.', textAlign: TextAlign.center),
          ),
        const SizedBox(height: 24),
      ]),
    );
  }

  void _all(String title, List<Cover> items) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: .78,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) => CoverTile(
              path: items[i].coverPath,
              title: items[i].title,
              subtitle: items[i].subtitle,
              onTap: () => openGrid(context, items[i].title, items[i].query),
            ),
          ),
        ),
      ));
}

Cover placeCover(Map<String, dynamic> p) {
  final city = p['city'] as String?, state = p['state'] as String?, country = (p['country'] as String?) ?? '';
  final title = city ?? state ?? country;
  final sub = [if (city != null && state != null) state, if (title != country) country].join(', ');
  return Cover(
    title: title,
    subtitle: sub.isEmpty ? '${p['count']} items' : '$sub · ${p['count']}',
    cover: p['cover'] as int?,
    coverV: (p['cover_v'] as String?) ?? '',
    // An empty value matches "no state" / "no city" on the server.
    query: {'country': country, 'state': state ?? '', 'city': city ?? ''},
  );
}

class _Strip extends StatelessWidget {
  const _Strip({required this.title, required this.items, required this.onAll});

  final String title;
  final List<Cover> items;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 4, 0),
        child: Row(children: [
          Expanded(child: Text(title, style: t.textTheme.titleMedium)),
          if (items.length > 6) TextButton(onPressed: onAll, child: const Text('See all')),
        ]),
      ),
      SizedBox(
        height: 170,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          itemCount: items.length > 20 ? 20 : items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, i) => SizedBox(
            width: 120,
            child: CoverTile(
              path: items[i].coverPath,
              title: items[i].title,
              subtitle: items[i].subtitle,
              onTap: () => openGrid(context, items[i].title, items[i].query),
            ),
          ),
        ),
      ),
    ]);
  }
}
