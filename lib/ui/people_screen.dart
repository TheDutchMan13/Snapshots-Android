import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/feed.dart';
import 'grid.dart';
import 'media.dart';
import 'theme.dart';

/// People found by face recognition on the PC. Named people first, then the ones not named yet.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key});

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  List<Person>? _people;
  String? _error;
  String? _faces;
  bool _hidden = false;
  int _hiddenCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await apiOf(context).get('/api/people', query: {'hidden': _hidden});
      if (!mounted) return;
      final f = r['faces'] as Map?;
      setState(() {
        _people = [for (final j in r['people'] as List) Person(Map<String, dynamic>.from(j as Map))];
        _hiddenCount = (r['hidden_count'] as int?) ?? 0;
        _faces = f == null
            ? null
            : f['enabled'] == false
                ? 'Face grouping is turned off on the PC (Settings > People and accounts).'
                : (f['running'] == true || ((f['pending'] as int?) ?? 0) > 0)
                    ? 'Still looking for faces: ${f['pending'] ?? 0} photos to go.'
                    : null;
        _error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _open(Person p) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonScreen(person: p)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    final named = people?.where((p) => p.named).toList() ?? const <Person>[];
    final unnamed = people?.where((p) => !p.named).toList() ?? const <Person>[];
    final t = Theme.of(context);
    Widget section(String title, List<Person> list) => SliverMainAxisGroup(slivers: [
          SliverToBoxAdapter(
            child: Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: Text(title, style: t.textTheme.titleSmall)),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 110,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: .78,
              ),
              itemCount: list.length,
              itemBuilder: (context, i) => _PersonTile(person: list[i], onTap: () => _open(list[i])),
            ),
          ),
        ]);
    return Scaffold(
      appBar: AppBar(title: Text(_hidden ? 'Hidden people' : 'People'), actions: [
        if (_hidden || _hiddenCount > 0)
          TextButton(
            onPressed: () {
              setState(() {
                _hidden = !_hidden;
                _people = null;
              });
              _load();
            },
            child: Text(_hidden ? 'Show people' : 'Hidden ($_hiddenCount)'),
          ),
      ]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
          if (_faces != null)
            SliverToBoxAdapter(
              child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text(_faces!, style: TextStyle(color: t.colorScheme.onSurfaceVariant))),
            ),
          if (people == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(child: _error != null ? Text(_error!, textAlign: TextAlign.center) : const CircularProgressIndicator()),
              ),
            )
          else if (people.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_hidden ? 'Nobody is hidden.' : 'No people found yet.', textAlign: TextAlign.center),
              ),
            )
          else ...[
            if (named.isNotEmpty) section(_hidden ? 'Named' : 'People', named),
            if (unnamed.isNotEmpty) section('Not named yet', unnamed),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ]),
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.person, required this.onTap});

  final Person person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(children: [
        AspectRatio(aspectRatio: 1, child: ClipOval(child: ServerThumb(person.facePath, icon: Icons.person_outline))),
        const SizedBox(height: 6),
        Text(person.named ? person.name! : 'Add a name',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: person.named ? t.textTheme.bodyMedium : t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.primary)),
        Text('${person.photos}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class PersonScreen extends StatefulWidget {
  const PersonScreen({super.key, required this.person});

  final Person person;

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<PersonScreen> {
  late Person _p = widget.person;
  late final Feed _feed = Feed(apiOf(context), {'person': widget.person.id, 'stacks': true});

  Future<void> _patch(Map<String, dynamic> body, String done) async {
    try {
      final r = await apiOf(context).patch('/api/people/${_p.id}', body);
      if (!mounted) return;
      setState(() => _p = Person(Map<String, dynamic>.from(r as Map)));
      showMessage(context, done);
    } on ApiError catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _name() async {
    final name = await askText(context, _p.named ? 'Rename' : 'Who is this?', initial: _p.name ?? '', label: 'Name');
    if (name == null || !mounted) return;
    await _patch({'name': name}, 'Named $name');
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return GridScreen(
      title: p.named ? p.name! : 'Not named yet',
      feed: _feed,
      emptyText: 'No photos of this person.',
      header: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(children: [
          SizedBox(width: 56, height: 56, child: ClipOval(child: ServerThumb(p.facePath, icon: Icons.person_outline))),
          const SizedBox(width: 12),
          Expanded(child: Text('${p.photos} photos${p.hidden ? ' · hidden' : ''}')),
          if (!p.named) FilledButton.tonal(onPressed: _name, child: const Text('Add a name')),
        ]),
      ),
      actions: [
        PopupMenuButton<String>(
          itemBuilder: (_) => [
            PopupMenuItem(value: 'name', child: Text(p.named ? 'Rename' : 'Add a name')),
            PopupMenuItem(value: 'hide', child: Text(p.hidden ? 'Show in People' : 'Hide from People')),
          ],
          onSelected: (v) => v == 'name'
              ? _name()
              : _patch({'hidden': !p.hidden}, p.hidden ? 'Shown in People again' : 'Hidden from People'),
        ),
      ],
    );
  }
}
