import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../backup/background.dart';
import '../backup/backup_db.dart';
import '../state/feed.dart';
import '../state/session.dart';
import 'backup_screen.dart';
import 'grid.dart';
import 'media.dart';
import 'theme.dart';

const appVersion = '0.1.0';

class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key});

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  Map<String, dynamic>? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await apiOf(context).get('/api/status');
      if (mounted) setState(() => _status = Map<String, dynamic>.from(r as Map));
    } on ApiError {
      // Shown without the numbers.
    }
  }

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  Future<void> _locked() async {
    final locked = (_status?['locked'] as Map?) ?? const {};
    if (locked['has_pin'] != true) {
      showMessage(context, 'Set a PIN for the locked folder in Snapshots on the PC first.');
      return;
    }
    if (locked['open'] != true) {
      final pin = await askText(context, 'Locked folder', label: 'PIN', ok: 'Open');
      if (pin == null || !mounted) return;
      try {
        await apiOf(context).post('/api/locked/open', {'pin': pin});
      } on ApiError catch (e) {
        if (mounted) showMessage(context, e.message);
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (c) => GridScreen(
        title: 'Locked folder',
        feed: Feed(apiOf(c), const {'locked': true}),
        mode: GridMode.locked,
        emptyText: 'Nothing in the locked folder. Move photos here from Snapshots on the PC.',
      ),
    ));
    if (!mounted) return;
    try {
      await apiOf(context).post('/api/locked/close');
    } on ApiError {
      // It closes by itself after 10 minutes.
    }
    _load();
  }

  Future<void> _signOut({bool change = false}) async {
    final session = context.read<Session>();
    final ok = await confirm(
      context,
      change ? 'Use another PC?' : 'Sign out?',
      'Backup stops until you sign in again. Photos already backed up stay in Snapshots.',
      ok: change ? 'Continue' : 'Sign out',
    );
    if (!ok) return;
    await Backup.cancelAll();
    if (change) {
      await (await BackupDb.open()).clear();
      await session.changeServer();
    } else {
      await session.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final s = _status;
    final trashed = s?['trashed'] as int?;
    final lockedCount = (s?['locked'] as Map?)?['count'] as int?;
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: [
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('Backup'),
            subtitle: const Text('Send this phone\'s photos and videos to Snapshots'),
            onTap: () => _push(const BackupScreen()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.favorite_border),
            title: const Text('Favourites'),
            onTap: () => openGrid(context, 'Favourites', {'favorite': true, 'stacks': true}, empty: 'No favourites yet. Tap ♡ on a photo.'),
          ),
          ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: const Text('Videos'),
            onTap: () => openGrid(context, 'Videos', {'kind': 'video', 'archived': 'hide', 'stacks': true}),
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Archive'),
            subtitle: const Text('Hidden from Photos, still in albums and search'),
            onTap: () => openGrid(context, 'Archive', {'archived': 'only'}, mode: GridMode.archive, empty: 'Nothing archived.'),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Locked folder'),
            subtitle: lockedCount == null ? null : Text('$lockedCount items'),
            onTap: _locked,
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Trash'),
            subtitle: trashed == null ? null : Text('$trashed items'),
            onTap: () => openGrid(
              context,
              'Trash',
              {'trashed': true},
              mode: GridMode.trash,
              empty: 'The trash is empty.',
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.computer_outlined),
            title: Text(session.server.replaceFirst(RegExp('^https?://'), '')),
            subtitle: Text([
              'Signed in as ${session.user?.username ?? ''}',
              if (s?['version'] != null) 'Snapshots ${s!['version']}',
              if (s != null) '${s['photos']} photos, ${s['videos']} videos',
            ].join('\n')),
            isThreeLine: s != null,
          ),
          ListTile(leading: const Icon(Icons.logout), title: const Text('Sign out'), onTap: () => _signOut()),
          ListTile(leading: const Icon(Icons.swap_horiz), title: const Text('Use another PC'), onTap: () => _signOut(change: true)),
          const Divider(),
          AboutListTile(
            icon: const Icon(Icons.info_outline),
            applicationName: 'Snapshots for Android',
            applicationVersion: appVersion,
            applicationLegalese: 'Copyright © 2026 Hans De Kryger\nGNU General Public License v3.0',
            aboutBoxChildren: const [
              SizedBox(height: 12),
              Text('Backs up your phone to your own Snapshots PC and shows your library. github.com/TheDutchMan13/Snapshots-Android'),
            ],
          ),
        ]),
      ),
    );
  }
}
