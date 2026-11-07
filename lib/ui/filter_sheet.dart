import 'package:flutter/material.dart';

import '../api/client.dart';
import '../state/feed.dart';
import 'details.dart';
import 'media.dart';

/// The Filter menu, as on the PC: stars, colour label, pick or reject, size, shape, black and white, camera.
/// Choices are sent as /api/assets parameters and kept on the grid's [Feed].
class FilterButton extends StatelessWidget {
  const FilterButton({super.key, required this.feed});

  final Feed feed;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: feed,
        builder: (context, _) {
          final on = feed.filter.length;
          return IconButton(
            tooltip: on == 0 ? 'Filter' : 'Filter ($on on)',
            icon: Badge(isLabelVisible: on > 0, label: Text('$on'), child: Icon(on > 0 ? Icons.filter_alt : Icons.filter_alt_outlined)),
            onPressed: () => showFilter(context, feed),
          );
        },
      );
}

/// The cameras in the library, asked once per run.
List<({String name, int count})>? _cameras;

Future<void> showFilter(BuildContext context, Feed feed) async {
  final api = apiOf(context);
  final f = Map<String, dynamic>.from(feed.filter);
  if (_cameras == null) {
    try {
      final r = await api.get('/api/cameras');
      _cameras = [for (final c in r['cameras'] as List) (name: c['name'] as String, count: (c['count'] as num).toInt())];
    } on ApiError {
      _cameras = const []; // an older Snapshots: no camera list
    } catch (_) {
      _cameras = const [];
    }
  }
  if (!context.mounted) return;
  final cameras = _cameras!;
  final result = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => StatefulBuilder(builder: (c, set) {
      final t = Theme.of(c);
      void toggle(String key, Object value) => set(() => f[key] == value ? f.remove(key) : f[key] = value);
      Widget heading(String s) =>
          Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 6), child: Text(s, style: t.textTheme.titleSmall));
      Widget chips(String key, List<(Object, String)> options, {IconData? icon}) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 8, runSpacing: 4, children: [
              for (final (value, text) in options)
                FilterChip(
                  avatar: icon == null ? null : Icon(icon, size: 18, color: const Color(0xFFF5A623)),
                  label: Text(text),
                  selected: f[key] == value,
                  showCheckmark: icon == null,
                  onSelected: (_) => toggle(key, value),
                ),
            ]),
          );
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: .75,
        maxChildSize: .95,
        builder: (c, scroll) => Column(children: [
          Expanded(child: ListView(controller: scroll, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(children: [
              Expanded(child: Text('Filter', style: t.textTheme.titleLarge)),
              TextButton(onPressed: f.isEmpty ? null : () => set(f.clear), child: const Text('Show everything')),
            ]),
          ),
          heading('Stars'),
          chips('rating', [for (var s = 1; s <= 5; s++) (s, s == 5 ? '5' : '$s+')], icon: Icons.star),
          heading('Colour label'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 8, children: [
              for (final e in labelColors.entries)
                FilterChip(
                  avatar: CircleAvatar(backgroundColor: e.value, radius: 8),
                  label: Text(labelName(e.key)),
                  selected: f['label'] == e.key,
                  onSelected: (_) => toggle('label', e.key),
                ),
            ]),
          ),
          heading('Pick or reject'),
          chips('flag', [('pick', 'Picks'), ('reject', 'Rejects'), ('unflagged', 'Neither')]),
          heading('Size'),
          chips('megapixels', [(2, '2 MP+'), (8, '8 MP+'), (12, '12 MP+'), (24, '24 MP+'), (48, '48 MP+')]),
          heading('Shape'),
          chips('shape', [('landscape', 'Landscape'), ('portrait', 'Portrait'), ('square', 'Square')]),
          heading('Colour'),
          chips('mono', [(true, 'Black and white')]),
          if (cameras.isNotEmpty) ...[
            heading('Camera'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                initialValue: f['camera'] as String? ?? '',
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: '', child: Text('Any camera')),
                  for (final cam in cameras) DropdownMenuItem(value: cam.name, child: Text('${cam.name} (${cam.count})')),
                ],
                onChanged: (v) => set(() => (v == null || v.isEmpty) ? f.remove('camera') : f['camera'] = v),
              ),
            ),
          ],
            const SizedBox(height: 12),
          ])),
          // Always in view, under the choices.
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(c, f), child: const Text('Show'))),
            ),
          ),
        ]),
      );
    }),
  );
  if (result == null) return;
  await feed.setFilter(result);
}
