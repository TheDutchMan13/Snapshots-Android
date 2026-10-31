import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';

import '../backup/background.dart';
import '../backup/backup_db.dart';
import '../backup/backup_service.dart';
import '../backup/backup_state.dart';
import 'theme.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> with WidgetsBindingObserver {
  BackupSettings? _s;
  BackupStatus _status = BackupStatus();
  PermissionState? _perm;
  List<AssetPathEntity> _albums = const [];
  final Map<String, int> _albumCounts = {};
  int _sent = 0, _rejected = 0;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Android's settings, where the permission may have changed.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final s = await BackupSettings.load();
    final perm = await PhotoManager.getPermissionState(requestOption: backupPermission);
    var albums = <AssetPathEntity>[];
    if (perm.hasAccess) {
      albums = (await PhotoManager.getAssetPathList(type: s.videos ? RequestType.common : RequestType.image))
          .where((p) => !p.isAll)
          .toList();
      for (final a in albums) {
        _albumCounts[a.id] = await a.assetCountAsync;
      }
      albums.sort((a, b) => (_albumCounts[b.id] ?? 0).compareTo(_albumCounts[a.id] ?? 0));
    }
    if (!mounted) return;
    setState(() {
      _s = s;
      _perm = perm;
      _albums = albums;
    });
    await _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final st = await BackupStatus.load();
    final db = await BackupDb.open();
    final sent = await db.count('sent'), rejected = await db.count('rejected');
    if (!mounted) return;
    setState(() {
      _status = st;
      _sent = sent;
      _rejected = rejected;
    });
  }

  Future<void> _save() async {
    await _s!.save();
    await Backup.schedule();
    setState(() {});
  }

  Future<void> _askPermission() async {
    final p = await PhotoManager.requestPermissionExtend(requestOption: backupPermission);
    if (!p.hasAccess && mounted) {
      final open = await confirm(context, 'Allow access to photos',
          'Snapshots needs access to all your photos and videos to back them up. Open Android settings to allow it?',
          ok: 'Open settings');
      if (open) await PhotoManager.openSetting();
    }
    await _load();
  }

  Future<void> _now() async {
    await Backup.now();
    if (mounted) showMessage(context, _s!.wifiOnly ? 'Backing up (as soon as the phone is on Wi-Fi)…' : 'Backing up…');
  }

  Future<void> _showRejected() async {
    final db = await BackupDb.open();
    final list = await db.rejected();
    if (!mounted) return;
    final retry = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Couldn't be backed up"),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            for (final r in list) ListTile(dense: true, title: Text(r.name), subtitle: Text(r.reason)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Close')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Try again')),
        ],
      ),
    );
    if (retry == true) {
      await db.retryRejected();
      await _now();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final t = Theme.of(context);
    if (s == null || _perm == null) {
      return Scaffold(appBar: AppBar(title: const Text('Backup')), body: const Center(child: CircularProgressIndicator()));
    }
    final st = _status;
    final access = _perm!.hasAccess;
    final limited = _perm == PermissionState.limited;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        if (!access || limited)
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(limited ? 'Snapshots can only see some of your photos' : 'Allow access to your photos',
                    style: t.textTheme.titleMedium),
                const SizedBox(height: 6),
                const Text('To back up, Snapshots needs to read all your photos and videos, including where they were taken.'),
                const SizedBox(height: 12),
                FilledButton(onPressed: _askPermission, child: const Text('Allow access')),
              ]),
            ),
          ),
        _statusCard(st),
        SwitchListTile(
          title: const Text('Back up automatically'),
          subtitle: const Text('About once an hour, in the background'),
          value: s.enabled,
          onChanged: access
              ? (v) {
                  s.enabled = v;
                  _save();
                  if (v) _now();
                }
              : null,
        ),
        SwitchListTile(
          title: const Text('Only on Wi-Fi'),
          subtitle: const Text('Saves mobile data. Tailscale works on both.'),
          value: s.wifiOnly,
          onChanged: (v) {
            s.wifiOnly = v;
            _save();
          },
        ),
        SwitchListTile(
          title: const Text('Only while charging'),
          value: s.chargingOnly,
          onChanged: (v) {
            s.chargingOnly = v;
            _save();
          },
        ),
        SwitchListTile(
          title: const Text('Include videos'),
          value: s.videos,
          onChanged: (v) {
            s.videos = v;
            _save().then((_) => _load());
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text('What to back up', style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary)),
        ),
        RadioGroup<bool>(
          groupValue: s.allAlbums,
          onChanged: (v) {
            s.allAlbums = v ?? false;
            _save();
          },
          child: const Column(children: [
            RadioListTile<bool>(value: false, title: Text('Chosen folders'), subtitle: Text('The camera, unless you pick others below')),
            RadioListTile<bool>(value: true, title: Text('Everything on the phone'), subtitle: Text('Includes screenshots, downloads and app folders')),
          ]),
        ),
        if (!s.allAlbums && access)
          for (final a in _albums)
            CheckboxListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 40, right: 16),
              title: Text(a.name),
              subtitle: Text('${_albumCounts[a.id] ?? 0}'),
              value: s.albums.isEmpty ? a.name.toLowerCase() == 'camera' : s.albums.contains(a.id),
              onChanged: (v) {
                var list = s.albums.isEmpty
                    ? [for (final x in _albums) if (x.name.toLowerCase() == 'camera') x.id]
                    : [...s.albums];
                if (v == true) {
                  list.add(a.id);
                } else {
                  list.remove(a.id);
                }
                list = list.toSet().toList();
                // Nothing picked: back to the default (the camera).
                s.albums = list;
                _save();
              },
            ),
      ]),
    );
  }

  Widget _statusCard(BackupStatus st) {
    final t = Theme.of(context);
    final when = st.lastFinished > 0 ? DateFormat.MMMd().add_jm().format(DateTime.fromMillisecondsSinceEpoch(st.lastFinished)) : null;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(st.running ? Icons.cloud_sync_outlined : Icons.cloud_done_outlined, color: t.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(st.running ? '${st.phase}…' : 'Backed up: $_sent', style: t.textTheme.titleMedium)),
          ]),
          if (st.running) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: st.total > 0 ? st.done / st.total : null),
            const SizedBox(height: 6),
            Text(st.total > 0 ? '${st.done} of ${st.total}${st.current.isNotEmpty ? ' · ${st.current}' : ''}' : st.current,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ] else if (st.lastResult.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(st.lastResult),
            if (when != null) Text('Last run: $when', style: t.textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            if (st.running)
              OutlinedButton(onPressed: Backup.stop, child: const Text('Stop'))
            else
              FilledButton.icon(
                onPressed: _perm?.hasAccess == true ? _now : null,
                icon: const Icon(Icons.backup_outlined),
                label: const Text('Back up now'),
              ),
            if (_rejected > 0) TextButton(onPressed: _showRejected, child: Text("$_rejected couldn't be backed up")),
          ]),
        ]),
      ),
    );
  }
}
