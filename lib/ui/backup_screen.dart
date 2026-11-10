import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../backup/background.dart';
import '../backup/backup_db.dart';
import '../backup/backup_service.dart';
import '../backup/backup_state.dart';
import '../backup/free_space.dart';
import '../state/session.dart';
import 'media.dart';
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
    context.read<Session>().refreshServerVersion();
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
    await Backup.askToNotify();
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
        if (context.watch<Session>().serverTooOld)
          Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Snapshots on your PC is version ${context.read<Session>().serverVersion}. Update it to ${Session.minServerVersion} or newer: '
                'until then a photo the PC lost is not sent again, and Free up space will not remove anything.',
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          ),
        _statusCard(st),
        if (access && _sent > 0)
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Free up space'),
            subtitle: const Text('Remove photos and videos from this phone that are safely in Snapshots'),
            onTap: _freeSpace,
          ),
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

  Future<void> _freeSpace() async {
    final api = apiOf(context);
    final busy = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(content: Row(children: [
        CircularProgressIndicator(),
        SizedBox(width: 20),
        Expanded(child: Text('Checking which ones are safely in Snapshots…')),
      ])),
    );
    FreeSpace? found;
    String? error;
    try {
      found = await FreeSpace.find(api);
    } on ApiError catch (e) {
      error = e.message;
    } catch (e) {
      error = "Couldn't check: $e";
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    await busy;
    if (!mounted) return;
    if (found == null) {
      showMessage(context, error ?? "Couldn't check.");
      return;
    }
    if (found.items.isEmpty) {
      showMessage(context, 'Nothing to remove: no photo on this phone is both backed up and unchanged since.');
      return;
    }
    final old = found.olderThan(30);
    final choice = await showModalBottomSheet<List<AssetEntity>>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('These stay in Snapshots on your PC, and you can still see them in this app. '
                'Only the copies on this phone are removed. Android asks you to confirm.'),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: Text('Older than 30 days (${old.length})'),
            enabled: old.isNotEmpty,
            onTap: () => Navigator.pop(c, old),
          ),
          ListTile(
            leading: const Icon(Icons.select_all),
            title: Text('Everything backed up (${found!.items.length})'),
            onTap: () => Navigator.pop(c, found!.items),
          ),
        ]),
      ),
    );
    if (choice == null || choice.isEmpty || !mounted) return;
    try {
      final r = await found.remove(choice);
      final held = r.held == 0 ? '' : " ${r.held} stayed on the phone: Snapshots couldn't confirm ${r.held == 1 ? 'it' : 'them'} just now.";
      if (mounted) {
        showMessage(context, r.gone == 0 ? 'Nothing was removed.$held' : 'Removed ${r.gone} from this phone. They\'re still in Snapshots.$held');
      }
    } catch (e) {
      if (mounted) showMessage(context, "Couldn't remove them: $e");
    }
    _load();
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
            if (st.lastWaiting > 0)
              Text('${st.lastWaiting} ${st.lastWaiting == 1 ? 'photo is' : 'photos are'} waiting to be backed up',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary)),
          ],
          if (!st.running && BackupStatus.staleWarning(st.lastFinished, DateTime.now()) != null) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: t.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(child: Text(BackupStatus.staleWarning(st.lastFinished, DateTime.now())!, style: TextStyle(color: t.colorScheme.error))),
            ]),
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
