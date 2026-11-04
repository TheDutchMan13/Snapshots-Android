import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'media.dart';
import 'theme.dart';

/// Things you can do with one or more photos, shared by the grids and the viewer.
class AssetActions {
  AssetActions(this.context) : api = apiOf(context);

  final BuildContext context;
  final Api api;

  Future<bool> _try(Future<void> Function() job, {String? done}) async {
    try {
      await job();
      if (done != null && context.mounted) showMessage(context, done);
      return true;
    } on ApiError catch (e) {
      if (context.mounted) showMessage(context, e.message);
      return false;
    }
  }

  Future<bool> favorite(List<Asset> items, bool value) => _try(() async {
        await api.post('/api/favorites', {'ids': [for (final a in items) a.id], 'value': value});
        for (final a in items) {
          a.favorite = value;
        }
      });

  Future<bool> archive(List<Asset> items, bool value) => _try(() async {
        await api.post('/api/archive', {'ids': [for (final a in items) a.id], 'value': value});
        for (final a in items) {
          a.archived = value;
        }
      }, done: value ? '${_n(items)} archived' : '${_n(items)} back in Photos');

  Future<bool> trash(List<Asset> items) async {
    final ok = await confirm(context, 'Move to trash?',
        '${_n(items)} will move to the trash on your Snapshots PC, for everyone who uses it. You can restore from the trash.',
        ok: 'Move to trash', danger: true);
    if (!ok || !context.mounted) return false;
    return _try(() => api.post('/api/trash', {'ids': [for (final a in items) a.id]}), done: '${_n(items)} moved to the trash');
  }

  Future<bool> restore(List<Asset> items) =>
      _try(() => api.post('/api/trash/restore', {'ids': [for (final a in items) a.id]}), done: '${_n(items)} restored');

  Future<bool> deleteForever(List<Asset> items) async {
    final ok = await confirm(context, 'Delete for good?',
        '${_n(items)} will be deleted from the PC\'s disk. This can\'t be undone.',
        ok: 'Delete', danger: true);
    if (!ok || !context.mounted) return false;
    return _try(() async {
      final r = await api.post('/api/trash/empty', {'ids': [for (final a in items) a.id]});
      final failed = (r['failed'] as List?)?.length ?? 0;
      if (failed > 0) throw ApiError('$failed could not be deleted.');
    }, done: '${_n(items)} deleted');
  }

  /// Pick an album (or make a new one) and add the photos to it.
  Future<bool> addToAlbum(List<Asset> items) async {
    final albums = <Album>[];
    try {
      final r = await api.get('/api/albums');
      albums.addAll([for (final j in r['albums'] as List) Album(Map<String, dynamic>.from(j as Map))].where((a) => !a.smart));
    } on ApiError catch (e) {
      if (context.mounted) showMessage(context, e.message);
      return false;
    }
    if (!context.mounted) return false;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .6,
        builder: (c, scroll) => ListView(
          controller: scroll,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New album'),
              onTap: () => Navigator.pop(c, 'new'),
            ),
            for (final a in albums)
              ListTile(
                leading: SizedBox(width: 48, height: 48, child: ClipRRect(borderRadius: BorderRadius.circular(6), child: ServerThumb(a.coverPath))),
                title: Text(a.name),
                subtitle: Text('${a.count} items'),
                onTap: () => Navigator.pop(c, a),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return false;
    final ids = [for (final a in items) a.id];
    if (picked == 'new') {
      final name = await askText(context, 'New album', label: 'Name', ok: 'Create');
      if (name == null || !context.mounted) return false;
      return _try(() => api.post('/api/albums', {'name': name, 'ids': ids}), done: 'Added to $name');
    }
    final album = picked as Album;
    return _try(() => api.post('/api/albums/${album.id}/add', {'ids': ids}), done: 'Added to ${album.name}');
  }

  Future<bool> removeFromAlbum(int albumId, List<Asset> items) => _try(
      () => api.post('/api/albums/$albumId/remove', {'ids': [for (final a in items) a.id]}),
      done: '${_n(items)} removed from the album');

  static Future<Directory> _shareDir() async => Directory(p.join((await getTemporaryDirectory()).path, 'share'));

  /// Deletes the originals downloaded for sharing (on app start and after the locked folder).
  static Future<void> clearShared() async {
    try {
      final dir = await _shareDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Tried again next time.
    }
  }

  /// Downloads the originals into the app's cache, with a progress dialog. Null if cancelled.
  Future<List<File>?> _download(List<Asset> items) async {
    final dir = await _shareDir();
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final cancel = CancelToken();
    final progress = ValueNotifier<double?>(null);
    final files = <File>[];
    if (!context.mounted) return null;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => PopScope(
        // Back cancels the download (the dialog closes when it has stopped).
        canPop: false,
        onPopInvokedWithResult: (didPop, _) => cancel.cancel(),
        child: AlertDialog(
        title: Text(items.length == 1 ? 'Getting the photo…' : 'Getting ${items.length} items…'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, _) => LinearProgressIndicator(value: v),
        ),
        actions: [TextButton(onPressed: () => cancel.cancel(), child: const Text('Cancel'))],
      )),
    );
    var ok = false;
    try {
      final total = items.fold<int>(0, (s, a) => s + a.size);
      var before = 0;
      for (final a in items) {
        final out = File(p.join(dir.path, '${a.id}', _safeName(a.filename, a.id)));
        await out.parent.create();
        await api.dio.download(api.url(a.originalPath()), out.path,
            options: Options(headers: api.authHeaders),
            cancelToken: cancel,
            onReceiveProgress: (got, _) => progress.value = total > 0 ? (before + got) / total : null);
        before += a.size;
        files.add(out);
      }
      ok = true;
    } on DioException catch (e) {
      if (!CancelToken.isCancel(e) && context.mounted) showMessage(context, api.toApiError(e).message);
    } finally {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      await dialog;
    }
    return ok ? files : null;
  }

  /// With [keep] false (the locked folder), the downloaded copies are deleted once the share
  /// sheet closes.
  Future<void> share(List<Asset> items, {bool keep = true}) async {
    final files = await _download(items);
    if (files == null) return;
    try {
      await SharePlus.instance.share(ShareParams(files: [for (final f in files) XFile(f.path)]));
    } finally {
      if (!keep) {
        for (final f in files) {
          try {
            await f.parent.delete(recursive: true);
          } catch (_) {}
        }
      }
    }
  }

  /// Saves the originals to the phone's gallery (Pictures/Snapshots, Movies/Snapshots).
  Future<void> saveToPhone(List<Asset> items) async {
    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.hasAccess) {
      if (context.mounted) showMessage(context, 'Snapshots needs access to your photos to save them.');
      return;
    }
    final files = await _download(items);
    if (files == null) return;
    var saved = 0;
    for (var i = 0; i < files.length; i++) {
      final f = files[i], a = items[i];
      try {
        if (a.isVideo) {
          await PhotoManager.editor.saveVideo(f, title: a.filename, relativePath: 'Movies/Snapshots');
        } else {
          await PhotoManager.editor.saveImageWithPath(f.path, title: a.filename, relativePath: 'Pictures/Snapshots');
        }
        saved++;
      } catch (_) {
        // Counted below.
      }
    }
    if (context.mounted) {
      showMessage(context, saved == files.length ? 'Saved to your phone' : 'Saved $saved of ${files.length}');
    }
  }

  static String _safeName(String name, int id) {
    final clean = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return clean.isEmpty ? 'snapshot-$id' : clean;
  }

  static String _n(List<Asset> items) => items.length == 1 ? '1 item' : '${items.length} items';
}
