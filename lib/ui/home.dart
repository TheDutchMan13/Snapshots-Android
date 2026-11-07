import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../backup/background.dart';
import '../api/models.dart';
import '../state/feed.dart';
import 'albums_screen.dart';
import 'backup_screen.dart';
import 'grid.dart';
import 'media.dart';
import 'more_screen.dart';
import 'people_screen.dart';
import 'search_screen.dart';
import 'theme.dart';

/// The tab bar: Photos, Albums, Search, People, More.
class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _tab = 0;
  final _photos = GlobalKey<GridScreenState>();
  late final Feed _timeline;

  /// The month the timeline was started at with "Jump to a month", or null.
  String? _jumped;

  Future<void> _pickMonth() async {
    List months;
    try {
      months = (await apiOf(context).get('/api/timeline', query: const {'archived': 'hide', 'stacks': true}))['months'] as List;
    } on ApiError catch (e) {
      if (mounted) showMessage(context, e.message);
      return;
    }
    if (!mounted || months.isEmpty) return;
    final fmt = DateFormat.MMMM();
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        builder: (c, scroll) {
          final rows = <Widget>[];
          String? year;
          for (final m in months) {
            final key = m['month'] as String;
            final y = key.substring(0, 4);
            if (y != year) {
              year = y;
              rows.add(Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(y, style: Theme.of(c).textTheme.titleMedium),
              ));
            }
            rows.add(ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 28),
              title: Text(fmt.format(DateTime(int.parse(y), int.parse(key.substring(5, 7))))),
              trailing: Text('${m['count']}'),
              onTap: () => Navigator.pop(c, key),
            ));
          }
          return ListView(controller: scroll, children: rows);
        },
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _jumped = picked == (months.first['month'] as String) ? null : picked);
    if (_jumped == null) {
      await _timeline.refresh();
    } else {
      await _timeline.jumpTo(picked);
    }
    _photos.currentState?.scrollToTop();
  }

  void _backToNewest() {
    setState(() => _jumped = null);
    _timeline.refresh();
  }

  @override
  void initState() {
    super.initState();
    _timeline = Feed(apiOf(context), const {'archived': 'hide', 'stacks': true});
    // Pick up photos taken since the last run (also right after signing in).
    Backup.onAppStart();
  }

  @override
  void dispose() {
    _timeline.dispose();
    super.dispose();
  }

  /// Hidden tabs are paused, so (for example) a selection on a hidden tab doesn't catch Back.
  List<Widget> _onlyActive(List<Widget> tabs) =>
      [for (var i = 0; i < tabs.length; i++) TickerMode(enabled: i == _tab, child: tabs[i])];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: _onlyActive([
        GridScreen(
          key: _photos,
          title: 'Photos',
          feed: _timeline,
          months: true,
          ownsFeed: false,
          filterable: true,
          header: _jumped == null
              ? const _Memories()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 8, 0),
                  child: Row(children: [
                    Expanded(child: Text('From ${DateFormat.yMMMM().format(DateTime.parse('$_jumped-01'))}')),
                    TextButton(onPressed: _backToNewest, child: const Text('Back to newest')),
                  ]),
                ),
          emptyText: 'No photos yet. Turn on backup to send the ones on this phone to Snapshots.',
          actions: [
            IconButton(tooltip: 'Jump to a month', icon: const Icon(Icons.calendar_month_outlined), onPressed: _pickMonth),
            IconButton(
              tooltip: 'Backup',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BackupScreen())),
            ),
          ],
        ),
        const AlbumsScreen(),
        const SearchScreen(),
        const PeopleScreen(),
        const MoreScreen(),
      ])),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          if (i == _tab && i == 0) _photos.currentState?.scrollToTop();
          setState(() => _tab = i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.photo_outlined), selectedIcon: Icon(Icons.photo), label: 'Photos'),
          NavigationDestination(icon: Icon(Icons.photo_album_outlined), selectedIcon: Icon(Icons.photo_album), label: 'Albums'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'People'),
          NavigationDestination(icon: Icon(Icons.menu), label: 'More'),
        ],
      ),
    );
  }
}

/// "On this day" in earlier years, above the timeline.
class _Memories extends StatefulWidget {
  const _Memories();

  @override
  State<_Memories> createState() => _MemoriesState();
}

class _MemoriesState extends State<_Memories> {
  List<Cover> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final r = await apiOf(context).get('/api/memories', query: {'today': today});
      final items = <Cover>[
        for (final m in (r['memories'] as List))
          Cover(
            title: m['years_ago'] == 1 ? '1 year ago' : '${m['years_ago']} years ago',
            subtitle: '${m['count']} items',
            cover: m['cover'] as int?,
            coverV: (m['cover_v'] as String?) ?? '',
            query: {
              'start': '${m['date']}T00:00:00',
              'end': '${m['date']}T23:59:59',
              'archived': 'hide',
              'stacks': true,
            },
          ),
      ];
      if (mounted) setState(() => _items = items);
    } on ApiError {
      // No memories strip; the timeline shows its own errors.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 158,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        itemCount: _items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final m = _items[i];
          return GestureDetector(
            onTap: () => openGrid(context, m.title, m.query),
            child: SizedBox(
              width: 110,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(fit: StackFit.expand, children: [
                  ServerThumb(m.coverPath),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.center, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black54]),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Text(m.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}
