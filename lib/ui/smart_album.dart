import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'details.dart';
import 'media.dart';
import 'theme.dart';

/// Make a smart album: it fills itself from rules (people, words, what's in the photo, dates, stars…), on the
/// PC as on the phone. Returns the new album, or null.
class SmartAlbumScreen extends StatefulWidget {
  const SmartAlbumScreen({super.key});

  @override
  State<SmartAlbumScreen> createState() => _SmartAlbumScreenState();
}

class _SmartAlbumScreenState extends State<SmartAlbumScreen> {
  final _name = TextEditingController();
  final _words = TextEditingController();
  final _look = TextEditingController();
  List<Person> _people = const [];
  final _chosen = <int>{};
  String _kind = '';
  DateTime? _start, _end;
  bool _favorite = false;
  int _rating = 0;
  String? _label;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadPeople();
  }

  Future<void> _loadPeople() async {
    try {
      final r = await apiOf(context).get('/api/people');
      if (!mounted) return;
      setState(() => _people = [for (final j in r['people'] as List) Person(Map<String, dynamic>.from(j as Map))].where((p) => p.named).toList());
    } catch (_) {
      // Shown without people to choose from.
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _words.dispose();
    _look.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _rule {
    final day = DateFormat('yyyy-MM-dd');
    return {
      if (_words.text.trim().isNotEmpty) 'words': _words.text.trim(),
      if (_look.text.trim().isNotEmpty) 'look': _look.text.trim(),
      if (_chosen.isNotEmpty) 'people': _chosen.toList(),
      if (_kind.isNotEmpty) 'kind': _kind,
      if (_start != null) 'start': day.format(_start!),
      if (_end != null) 'end': day.format(_end!),
      if (_favorite) 'favorite': true,
      if (_rating > 0) 'rating': _rating,
      if (_label != null) 'label': _label,
    };
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showMessage(context, 'Give the album a name.');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await apiOf(context).post('/api/albums', {'name': name, 'rule': _rule});
      if (mounted) Navigator.pop(context, Album(Map<String, dynamic>.from(r as Map)));
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showMessage(context, e.message);
      }
    }
  }

  Future<void> _date(bool start) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (start ? _start : _end) ?? now,
      firstDate: DateTime(1826),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked != null) setState(() => start ? _start = picked : _end = picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dates = DateFormat.yMMMd();
    Widget heading(String s, [String? help]) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s, style: t.textTheme.titleSmall),
            if (help != null) Text(help, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('New smart album'), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(onPressed: _saving ? null : _save, child: const Text('Create')),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('It fills itself with everything that matches all the rules below, now and later.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
        if (_people.isNotEmpty) ...[
          heading('People', 'Photos with all of them in it'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 8, runSpacing: 4, children: [
              for (final p in _people)
                FilterChip(
                  avatar: p.facePath == null ? null : CircleAvatar(backgroundImage: serverImage(apiOf(context), p.facePath!)),
                  label: Text(p.name!),
                  selected: _chosen.contains(p.id),
                  onSelected: (on) => setState(() => on ? _chosen.add(p.id) : _chosen.remove(p.id)),
                ),
            ]),
          ),
        ],
        heading('Words', 'Names, places, tags, descriptions, text in the photo'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(controller: _words, decoration: const InputDecoration(hintText: 'e.g. beach')),
        ),
        heading("What's in the photo", 'Found by what the photo shows, like a search by content'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(controller: _look, decoration: const InputDecoration(hintText: 'e.g. dogs playing in snow')),
        ),
        heading('Dates'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, children: [
            InputChip(
              label: Text(_start == null ? 'From any date' : 'From ${dates.format(_start!)}'),
              onPressed: () => _date(true),
              onDeleted: _start == null ? null : () => setState(() => _start = null),
            ),
            InputChip(
              label: Text(_end == null ? 'Until any date' : 'Until ${dates.format(_end!)}'),
              onPressed: () => _date(false),
              onDeleted: _end == null ? null : () => setState(() => _end = null),
            ),
          ]),
        ),
        heading('Kind'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '', label: Text('Both')),
              ButtonSegment(value: 'photo', label: Text('Photos')),
              ButtonSegment(value: 'video', label: Text('Videos')),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
        ),
        heading('Marks'),
        SwitchListTile(title: const Text('Favourites only'), value: _favorite, onChanged: (v) => setState(() => _favorite = v)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            for (var s = 1; s <= 5; s++)
              ChoiceChip(
                avatar: const Icon(Icons.star, size: 18, color: Color(0xFFF5A623)),
                showCheckmark: false,
                label: Text(s == 5 ? '5' : '$s+'),
                selected: _rating == s,
                onSelected: (on) => setState(() => _rating = on ? s : 0),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            for (final e in labelColors.entries)
              ChoiceChip(
                avatar: CircleAvatar(backgroundColor: e.value, radius: 8),
                label: Text(labelName(e.key)),
                selected: _label == e.key,
                onSelected: (on) => setState(() => _label = on ? e.key : null),
              ),
          ]),
        ),
      ]),
    );
  }
}
