import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'media.dart';
import 'theme.dart';

/// Colour labels, as Lightroom names them (and Snapshots on the PC shows them).
const labelColors = <String, Color>{
  'red': Color(0xFFE5484D),
  'yellow': Color(0xFFF5C400),
  'green': Color(0xFF30A46C),
  'blue': Color(0xFF3E7BFA),
  'purple': Color(0xFF8E4EC6),
};

String labelName(String l) => l[0].toUpperCase() + l.substring(1);

String _n(List<Asset> items) => items.length == 1 ? '1 item' : '${items.length} items';

/// Stars, a colour label and pick / reject: everything is saved at once, for every item given.
/// Returns true if something changed.
Future<bool> editMarks(BuildContext context, List<Asset> items) async {
  final first = items.first;
  var rating = items.every((a) => a.rating == first.rating) ? first.rating : -1;
  var label = items.every((a) => a.label == first.label) ? first.label : '?';
  var flag = items.every((a) => a.flag == first.flag) ? first.flag : 9;
  final changed = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (c) => StatefulBuilder(builder: (c, set) {
      final t = Theme.of(c);
      Widget heading(String s) =>
          Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 6), child: Text(s, style: t.textTheme.titleSmall));
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (items.length > 1)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Text('For ${_n(items)}')),
          heading('Stars'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              for (var s = 1; s <= 5; s++)
                IconButton(
                  tooltip: s == 1 ? '1 star' : '$s stars',
                  icon: Icon(s <= rating ? Icons.star : Icons.star_border, color: s <= rating ? const Color(0xFFF5A623) : null),
                  // Tapping the stars already given takes them away, as on the PC.
                  onPressed: () => set(() => rating = rating == s ? 0 : s),
                ),
              if (rating > 0) TextButton(onPressed: () => set(() => rating = 0), child: const Text('No stars')),
            ]),
          ),
          heading('Colour label'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 10, children: [
              for (final e in labelColors.entries)
                Tooltip(
                  message: labelName(e.key),
                  child: InkResponse(
                    onTap: () => set(() => label = label == e.key ? null : e.key),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: e.value,
                        shape: BoxShape.circle,
                        border: Border.all(color: label == e.key ? t.colorScheme.onSurface : Colors.transparent, width: 3),
                      ),
                      child: label == e.key ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                    ),
                  ),
                ),
            ]),
          ),
          heading('Pick or reject'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<int>(
              emptySelectionAllowed: true,
              segments: const [
                ButtonSegment(value: 1, icon: Icon(Icons.flag), label: Text('Pick')),
                ButtonSegment(value: 0, label: Text('Neither')),
                ButtonSegment(value: -1, icon: Icon(Icons.close), label: Text('Reject')),
              ],
              selected: {if (flag != 9) flag},
              onSelectionChanged: (v) => set(() => flag = v.isEmpty ? 0 : v.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
            ]),
          ),
        ]),
      );
    }),
  );
  if (changed != true || !context.mounted) return false;
  final body = <String, dynamic>{
    'ids': [for (final a in items) a.id],
    if (rating >= 0) 'rating': rating,
    if (label != '?') 'label': label ?? '',
    if (flag != 9) 'flag': flag,
  };
  if (body.length == 1) return false;
  try {
    await apiOf(context).post('/api/marks', body);
  } on ApiError catch (e) {
    if (context.mounted) showMessage(context, e.message);
    return false;
  }
  for (final a in items) {
    if (rating >= 0) a.rating = rating;
    if (label != '?') a.label = label;
    if (flag != 9) a.flag = flag;
  }
  return true;
}

Future<bool> _details(BuildContext context, List<Asset> items, Map<String, dynamic> change, String done) async {
  try {
    await apiOf(context).post('/api/assets/details', {'ids': [for (final a in items) a.id], ...change});
    if (context.mounted) showMessage(context, done);
    return true;
  } on ApiError catch (e) {
    if (context.mounted) showMessage(context, e.message);
    return false;
  }
}

/// Fix the date: set it, move it by some hours (a camera with a wrong clock), or go back to the file's own.
Future<bool> changeDate(BuildContext context, List<Asset> items) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.event),
          title: Text(items.length == 1 ? 'Set the date and time' : 'Give them all one date and time'),
          onTap: () => Navigator.pop(c, 'set'),
        ),
        ListTile(
          leading: const Icon(Icons.more_time),
          title: const Text('Move by some hours'),
          subtitle: const Text('For a camera whose clock was wrong'),
          onTap: () => Navigator.pop(c, 'shift'),
        ),
        ListTile(
          leading: const Icon(Icons.restore),
          title: const Text('Back to the date in the file'),
          onTap: () => Navigator.pop(c, 'reset'),
        ),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return false;
  switch (choice) {
    case 'set':
      final at = items.first.takenAt;
      final day = await showDatePicker(context: context, initialDate: at, firstDate: DateTime(1826), lastDate: DateTime(2200));
      if (day == null || !context.mounted) return false;
      final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(at));
      if (time == null || !context.mounted) return false;
      final when = DateTime(day.year, day.month, day.day, time.hour, time.minute, items.length == 1 ? at.second : 0);
      return _details(context, items, {'taken_at': DateFormat("yyyy-MM-dd'T'HH:mm:ss").format(when)},
          'Date changed to ${DateFormat.yMMMd().add_jm().format(when)}');
    case 'shift':
      final minutes = await _askShift(context);
      if (minutes == null || minutes == 0 || !context.mounted) return false;
      return _details(context, items, {'shift_minutes': minutes}, '${_n(items)} moved');
    default:
      return _details(context, items, {'reset_date': true}, 'Back to the date in the file');
  }
}

Future<int?> _askShift(BuildContext context) => showDialog<int>(
      context: context,
      builder: (c) {
        var hours = 0, minutes = 0;
        var later = true;
        return StatefulBuilder(builder: (c, set) {
          Widget stepper(String name, int value, int max, void Function(int) to) => Row(children: [
                Expanded(child: Text(name)),
                IconButton(onPressed: value > 0 ? () => set(() => to(value - 1)) : null, icon: const Icon(Icons.remove)),
                SizedBox(width: 40, child: Text('$value', textAlign: TextAlign.center, style: Theme.of(c).textTheme.titleMedium)),
                IconButton(onPressed: value < max ? () => set(() => to(value + 1)) : null, icon: const Icon(Icons.add)),
              ]);
          return AlertDialog(
            title: const Text('Move by'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Earlier')),
                  ButtonSegment(value: true, label: Text('Later')),
                ],
                selected: {later},
                onSelectionChanged: (v) => set(() => later = v.first),
              ),
              const SizedBox(height: 8),
              stepper('Hours', hours, 23 * 365, (v) => hours = v),
              stepper('Minutes', minutes, 59, (v) => minutes = v),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(c, (later ? 1 : -1) * (hours * 60 + minutes)),
                child: const Text('Move'),
              ),
            ],
          );
        });
      },
    );

/// Set the place: a town by name (from the PC's offline place list), coordinates, none, or the file's own.
Future<bool> changePlace(BuildContext context, List<Asset> items) async {
  final picked = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: const _PlacePicker(),
    ),
  );
  if (picked == null || !context.mounted) return false;
  if (picked == 'none') return _details(context, items, {'clear_position': true}, 'Location removed');
  if (picked == 'reset') return _details(context, items, {'reset_position': true}, 'Back to the location in the file');
  final p = picked as ({double lat, double lon, String name});
  return _details(context, items, {'position': [p.lat, p.lon]}, 'Location set to ${p.name}');
}

/// "33.45, -112.07" (as Google Maps copies it) as coordinates, or null.
({double lat, double lon})? parseCoordinates(String s) {
  final m = RegExp(r'^\s*(-?\d{1,3}(?:\.\d+)?)\s*[, ]\s*(-?\d{1,3}(?:\.\d+)?)\s*$').firstMatch(s);
  if (m == null) return null;
  final lat = double.parse(m[1]!), lon = double.parse(m[2]!);
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  return (lat: lat, lon: lon);
}

class _PlacePicker extends StatefulWidget {
  const _PlacePicker();

  @override
  State<_PlacePicker> createState() => _PlacePickerState();
}

class _PlacePickerState extends State<_PlacePicker> {
  final _text = TextEditingController();
  List<Map<String, dynamic>> _found = const [];
  String? _note;
  Timer? _wait;
  int _ask = 0;

  @override
  void dispose() {
    _wait?.cancel();
    _text.dispose();
    super.dispose();
  }

  static ({double lat, double lon})? coordinates(String s) => parseCoordinates(s);


  void _changed(String s) {
    _wait?.cancel();
    if (s.trim().length < 2 || coordinates(s) != null) {
      setState(() => _found = const []);
      return;
    }
    _wait = Timer(const Duration(milliseconds: 300), () async {
      final ask = ++_ask;
      try {
        final r = await apiOf(context).get('/api/places/search', query: {'q': s.trim()});
        if (!mounted || ask != _ask) return;
        final found = [for (final p in r['places'] as List) Map<String, dynamic>.from(p as Map)];
        setState(() {
          _found = found;
          _note = found.isEmpty ? 'No town by that name. The PC needs its place list (Settings > Places) to find towns.' : null;
        });
      } on ApiError catch (e) {
        if (mounted && ask == _ask) setState(() => _note = e.message);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final coords = coordinates(_text.text);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .7),
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _text,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'A town, or coordinates like 33.45, -112.07',
              ),
              onChanged: (s) {
                setState(() {});
                _changed(s);
              },
            ),
          ),
          if (coords != null)
            ListTile(
              leading: const Icon(Icons.my_location),
              title: Text('${coords.lat}, ${coords.lon}'),
              subtitle: const Text('Use these coordinates'),
              onTap: () => Navigator.pop(context, (lat: coords.lat, lon: coords.lon, name: '${coords.lat}, ${coords.lon}')),
            ),
          for (final p in _found)
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(p['city'] as String),
              subtitle: Text([p['state'], p['country']].whereType<String>().where((s) => s.isNotEmpty).join(', ')),
              onTap: () => Navigator.pop(context, (
                lat: (p['lat'] as num).toDouble(),
                lon: (p['lon'] as num).toDouble(),
                name: p['city'] as String,
              )),
            ),
          if (_note != null && _found.isEmpty && coords == null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_note!)),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.location_off_outlined),
            title: const Text('No location'),
            onTap: () => Navigator.pop(context, 'none'),
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Back to the location in the file'),
            onTap: () => Navigator.pop(context, 'reset'),
          ),
        ]),
      ),
    );
  }
}

/// A photo's description (shown in its details, found by search).
Future<bool> changeDescription(BuildContext context, Asset a, String? now) async {
  final ctl = TextEditingController(text: now ?? '');
  final r = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Description'),
      content: TextField(controller: ctl, autofocus: true, maxLines: 4, minLines: 2, maxLength: 5000),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
      ],
    ),
  );
  ctl.dispose();
  if (r == null || r == (now ?? '') || !context.mounted) return false;
  return _details(context, [a], {'description': r}, r.isEmpty ? 'Description removed' : 'Description saved');
}

/// Small marks on a tile: stars, label, pick or reject.
class MarksBadge extends StatelessWidget {
  const MarksBadge({super.key, required this.asset});

  final Asset asset;

  @override
  Widget build(BuildContext context) {
    final a = asset;
    if (a.rating == 0 && a.label == null && a.flag == 0) return const SizedBox.shrink();
    const shadow = [Shadow(blurRadius: 4)];
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (a.label != null)
        Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.only(right: 3),
          decoration: BoxDecoration(color: labelColors[a.label], shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1)),
        ),
      if (a.rating > 0) ...[
        const Icon(Icons.star, size: 12, color: Colors.white, shadows: shadow),
        Text('${a.rating}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600, shadows: shadow)),
      ],
      if (a.flag == 1) const Icon(Icons.flag, size: 12, color: Colors.white, shadows: shadow),
      if (a.flag == -1) const Icon(Icons.close, size: 12, color: Colors.white, shadows: shadow),
    ]);
  }
}
