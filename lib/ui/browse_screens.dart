import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/feed.dart';
import 'albums_screen.dart';
import 'grid.dart';
import 'media.dart';
import 'theme.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// A page that loads once and can be pulled to load again, with a message and "Try again" on failure.
class _Loaded<T> extends StatefulWidget {
  const _Loaded({super.key, required this.title, required this.load, required this.build, this.actions = const []});

  final String title;
  final Future<T> Function(Api api) load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) build;
  final List<Widget> actions;

  @override
  State<_Loaded<T>> createState() => _LoadedState<T>();
}

class _LoadedState<T> extends State<_Loaded<T>> {
  T? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final d = await widget.load(apiOf(context));
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    Widget body;
    if (d != null) {
      body = widget.build(context, d, _reload);
    } else {
      body = ListView(children: [
        Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: _error == null
                ? const CircularProgressIndicator()
                : Column(children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () {
                        setState(() => _error = null);
                        _reload();
                      },
                      child: const Text('Try again'),
                    ),
                  ]),
          ),
        ),
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: widget.actions),
      body: RefreshIndicator(onRefresh: _reload, child: body),
    );
  }
}

Widget _empty(String text) => ListView(children: [Padding(padding: const EdgeInsets.all(32), child: Text(text, textAlign: TextAlign.center))]);

Widget _covers(List<Widget> tiles) => GridView.count(
      padding: const EdgeInsets.all(12),
      crossAxisCount: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: .78,
      physics: const AlwaysScrollableScrollPhysics(),
      children: tiles,
    );

// ------------------------------------------------------------------ Calendar

/// Each month of a year, the days with photos shaded by how many. A day or month opens its photos.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  int? _year;

  @override
  Widget build(BuildContext context) {
    return _Loaded<Map<String, dynamic>>(
      key: ValueKey(_year),
      title: 'Calendar',
      load: (api) async => Map<String, dynamic>.from(
          await api.get('/api/calendar', query: {if (_year != null) 'year': _year}) as Map),
      build: (context, data, reload) {
        final year = data['year'] as int;
        final years = [for (final y in data['years'] as List) (y['year'] as int, y['count'] as int)];
        final days = {for (final e in (data['days'] as Map).entries) e.key as String: (e.value as num).toInt()};
        if (years.isEmpty) return _empty('No photos yet. Each day you took photos will show up here.');
        final counts = days.values.toList()..sort();
        final high = counts.isEmpty ? 1 : counts[(counts.length * .9).floor().clamp(0, counts.length - 1)];
        return ListView(children: [
          SizedBox(
            height: 52,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), children: [
              for (final (y, n) in years)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('$y'),
                    tooltip: '$n items',
                    selected: y == year,
                    onSelected: (_) => setState(() => _year = y),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth >= 600 ? 3 : 2;
              final w = (c.maxWidth - (cols - 1) * 16) / cols;
              return Wrap(spacing: 16, runSpacing: 20, children: [
                for (var m = 1; m <= 12; m++) SizedBox(width: w, child: _Month(year: year, month: m, days: days, high: high)),
              ]);
            }),
          ),
        ]);
      },
    );
  }
}

class _Month extends StatelessWidget {
  const _Month({required this.year, required this.month, required this.days, required this.high});

  final int year, month;
  final Map<String, int> days;
  final int high;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final key = '$year-${_two(month)}';
    final total = days.entries.where((e) => e.key.startsWith(key)).fold<int>(0, (s, e) => s + e.value);
    final first = MaterialLocalizations.of(context).firstDayOfWeekIndex; // 0 = Sunday
    final narrow = DateFormat.EEEEE();
    final start = (DateTime(year, month, 1).weekday % 7 - first + 7) % 7;
    final length = DateTime(year, month + 1, 0).day;
    final now = DateTime.now();
    final cells = <Widget>[
      for (var i = 0; i < 7; i++)
        Center(child: Text(narrow.format(DateTime(2023, 1, 1 + (i + first) % 7)), style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
      for (var i = 0; i < start; i++) const SizedBox(),
      for (var d = 1; d <= length; d++) _day(context, d, now),
    ];
    final name = DateFormat.MMMM().format(DateTime(year, month));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: total == 0
            ? null
            : () => openGrid(context, DateFormat.yMMMM().format(DateTime(year, month)), {
                  'start': '$key-01T00:00:00',
                  'end': '$key-${_two(length)}T23:59:59',
                  'archived': 'hide',
                  'stacks': true,
                }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: name, style: t.textTheme.titleSmall?.copyWith(color: total == 0 ? t.colorScheme.onSurfaceVariant : null)),
            if (total > 0) TextSpan(text: '  $total', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ])),
        ),
      ),
      GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        children: cells,
      ),
    ]);
  }

  Widget _day(BuildContext context, int d, DateTime now) {
    final t = Theme.of(context);
    final day = '$year-${_two(month)}-${_two(d)}';
    final n = days[day] ?? 0;
    final today = now.year == year && now.month == month && now.day == d;
    final level = n == 0 ? 0 : (n >= high ? 4 : n >= high / 2 ? 3 : n >= high / 5 ? 2 : 1);
    final bg = level == 0 ? null : t.colorScheme.primary.withValues(alpha: const <double>[0, .16, .32, .55, 1.0][level]);
    final text = Text('$d',
        style: TextStyle(
          fontSize: 11,
          fontWeight: n > 0 ? FontWeight.w600 : FontWeight.normal,
          color: level == 4 ? t.colorScheme.onPrimary : (n > 0 ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant.withValues(alpha: .6)),
        ));
    final box = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        border: today ? Border.all(color: t.colorScheme.onSurface, width: 1.5) : null,
      ),
      child: text,
    );
    if (n == 0) return box;
    final label = DateFormat.MMMMEEEEd().format(DateTime(year, month, d));
    return Semantics(
      label: '$label: $n items',
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: () => openGrid(context, DateFormat.yMMMMEEEEd().format(DateTime(year, month, d)),
            {'start': '${day}T00:00:00', 'end': '${day}T23:59:59', 'archived': 'hide', 'stacks': true}),
        child: box,
      ),
    );
  }
}

// ------------------------------------------------------------------ Events

/// Days out and trips Snapshots found, newest first.
class EventsScreen extends StatelessWidget {
  const EventsScreen({super.key});

  static String title(Map e) {
    final t = e['title'] as String?;
    if (t != null && t.isNotEmpty) return t;
    final place = e['place'] as String?;
    if (e['kind'] == 'trip') return place == null ? 'A trip' : 'Trip to $place';
    return place ?? 'A day out';
  }

  @override
  Widget build(BuildContext context) {
    final dates = DateFormat.yMMMd();
    return _Loaded<List<Map>>(
      title: 'Events',
      load: (api) async => [for (final e in (await api.get('/api/events'))['events'] as List) e as Map],
      build: (context, events, _) {
        if (events.isEmpty) return _empty('No events yet. Days out and trips show up here once there are enough photos.');
        return _covers([
          for (final e in events)
            CoverTile(
              path: e['cover'] == null ? null : '/api/assets/${e['cover']}/thumb?v=${e['cover_v'] ?? ''}',
              title: title(e),
              subtitle: [
                dates.format(DateTime.parse(e['start'] as String)),
                if ((e['days'] as num? ?? 1) > 1) '${e['days']} days',
                '${e['count']} items',
              ].join(' · '),
              icon: e['kind'] == 'trip' ? Icons.luggage_outlined : Icons.event_outlined,
              onTap: () => openGrid(context, title(e), {'start': e['start'], 'end': e['end'], 'archived': 'hide', 'stacks': true}),
            ),
        ]);
      },
    );
  }
}

// ------------------------------------------------------------------ Highlights

void openHighlights(BuildContext context) => openGrid(
      context,
      'Highlights',
      const {'highlights': true, 'archived': 'hide', 'stacks': true},
      empty: 'No highlights yet. Snapshots picks your best-looking photos once it has looked at them all.',
      filterable: true,
    );

// ------------------------------------------------------------------ Year in review

/// The best photos of each year, chosen by Snapshots (favourites, stars, picks, people, sharpness).
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _Loaded<List<Map>>(
      title: 'Year in review',
      load: (api) async => [for (final y in (await api.get('/api/review'))['years'] as List) y as Map],
      build: (context, years, _) {
        if (years.isEmpty) return _empty('No photos yet.');
        return ListView(children: [
          for (final y in years)
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: Text('${y['year']}'),
              subtitle: Text('${y['photos']} photos'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(context, y['year'] as int),
            ),
        ]);
      },
    );
  }

  static void _open(BuildContext context, int year) {
    Map<String, dynamic>? facts;
    final api = apiOf(context);
    final feed = Feed.fixed(api, () async {
      final r = Map<String, dynamic>.from(await api.post('/api/review/$year', {'count': 60}) as Map);
      facts = r;
      return [for (final j in r['items'] as List) Asset(Map<String, dynamic>.from(j as Map))];
    });
    Navigator.of(context).push(MaterialPageRoute(
      builder: (c) => GridScreen(
        title: '$year',
        feed: feed,
        emptyText: 'No photos from $year to choose from.',
        slideshow: true,
        header: ListenableBuilder(
          listenable: feed,
          builder: (c, _) {
            final f = facts;
            if (f == null || feed.items.isEmpty) return const SizedBox.shrink();
            final lines = [
              '${feed.items.length} of ${f['photos']} photos, from ${f['months']} months',
              if ((f['places'] as List).isNotEmpty) 'In ${(f['places'] as List).join(', ')}',
              if ((f['people'] as List).isNotEmpty) 'With ${(f['people'] as List).join(', ')}',
            ];
            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Text(lines.join('\n'), style: TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant)),
            );
          },
        ),
      ),
    ));
  }
}

// ------------------------------------------------------------------ Pets

/// Dogs and cats Snapshots found, grouped like People. Long-press to name one.
class PetsScreen extends StatelessWidget {
  const PetsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _Loaded<Map<String, dynamic>>(
      title: 'Pets',
      load: (api) async => Map<String, dynamic>.from(await api.get('/api/pets') as Map),
      build: (context, data, reload) {
        final pets = [for (final p in data['pets'] as List) p as Map];
        if (pets.isEmpty) {
          return _empty(data['enabled'] == false
              ? 'Finding pets is switched off in Snapshots on the PC (Settings).'
              : 'No pets found yet. Dogs and cats show up here once Snapshots has looked at your photos.');
        }
        Future<void> rename(Map p) async {
          final name = await askText(context, p['name'] == null ? 'Name this pet' : 'Rename', initial: (p['name'] as String?) ?? '', label: 'Name');
          if (name == null || !context.mounted) return;
          try {
            await apiOf(context).patch('/api/pets/${p['id']}', {'name': name});
            await reload();
          } on ApiError catch (e) {
            if (context.mounted) showMessage(context, e.message);
          }
        }

        return _covers([
          for (final p in pets)
            GestureDetector(
              onLongPress: () => rename(p),
              child: CoverTile(
                path: '/api/pets/${p['id']}/thumb',
                title: (p['name'] as String?) ?? (p['species'] == 'cat' ? 'A cat' : p['species'] == 'dog' ? 'A dog' : 'A pet'),
                subtitle: '${p['photos']} photos${p['name'] == null ? ' · hold to name' : ''}',
                icon: Icons.pets,
                onTap: () => openGrid(context, (p['name'] as String?) ?? 'Pet', {'pet': p['id'], 'archived': 'hide', 'stacks': true}),
              ),
            ),
        ]);
      },
    );
  }
}
