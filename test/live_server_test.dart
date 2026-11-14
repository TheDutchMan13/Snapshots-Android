// Talks to a real Snapshots server. Skipped unless SNAPSHOTS_TEST_SERVER is set, e.g.
//   SNAPSHOTS_TEST_SERVER=127.0.0.1:8790 SNAPSHOTS_TEST_USER=hans SNAPSHOTS_TEST_PASSWORD='…' flutter test test/live_server_test.dart
// Use a throwaway demo library: it uploads a photo and moves it to the trash and back.

import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshots_app/api/client.dart';
import 'package:snapshots_app/api/models.dart';
import 'package:snapshots_app/backup/library_check.dart';
import 'package:snapshots_app/state/feed.dart';

void main() {
  final env = Platform.environment;
  final server = env['SNAPSHOTS_TEST_SERVER'];
  final skip = server == null ? 'Set SNAPSHOTS_TEST_SERVER to run against a real server' : null;
  late Api api;

  setUpAll(() async {
    if (server == null) return;
    api = Api(server: server);
    final r = await api.post('/api/auth/login', {
      'username': env['SNAPSHOTS_TEST_USER'] ?? 'hans',
      'password': env['SNAPSHOTS_TEST_PASSWORD'] ?? 'demo password 1',
    });
    api.token = r['token'] as String;
    expect(api.deviceCookie, isNotNull, reason: 'the server gives a known-device cookie on login');
  });

  test('wrong password gives the server\'s sentence', () async {
    final a = Api(server: server!);
    await expectLater(
      a.post('/api/auth/login', {'username': 'hans', 'password': 'nope'}),
      throwsA(isA<ApiError>().having((e) => e.message, 'message', 'Wrong user name or password.')),
    );
  }, skip: skip);

  test('timeline pages through everything, newest first, without repeats', () async {
    final feed = Feed(api, const {'archived': 'hide', 'stacks': true}, pageSize: 25);
    while (!feed.done) {
      await feed.loadMore();
      expect(feed.error, isNull);
    }
    final ids = feed.items.map((a) => a.id).toList();
    expect(ids.toSet().length, ids.length);
    for (var i = 1; i < feed.items.length; i++) {
      expect(!feed.items[i].takenAt.isAfter(feed.items[i - 1].takenAt), isTrue);
    }
    final months = (await api.get('/api/timeline', query: {'archived': 'hide', 'stacks': true}))['months'] as List;
    if (months.isEmpty) {
      markTestSkipped('This server has no photos: use the demo library (see the top of this file).');
      return;
    }
    expect(feed.items.length, months.fold<int>(0, (s, m) => s + (m['count'] as int)));

    // Jumping to a month starts there.
    final m = months[months.length ~/ 2]['month'] as String;
    await feed.jumpTo(m);
    expect(feed.items.first.monthKey, m);
  }, skip: skip);

  test('thumbnails and full photos load with the token', () async {
    final page = await api.get('/api/assets', query: {'limit': 1});
    final a = Asset(Map<String, dynamic>.from(page['items'][0] as Map));
    for (final path in [a.thumbPath(), a.viewPath()]) {
      final r = await api.dio.get<List<int>>(path, options: Options(responseType: ResponseType.bytes, headers: api.authHeaders));
      expect(r.statusCode, 200);
      expect(r.data!.length, greaterThan(1000));
    }
    final d = AssetDetail(Map<String, dynamic>.from(await api.get('/api/assets/${a.id}') as Map));
    expect(d.asset.id, a.id);
  }, skip: skip);

  test('an edit is written into the photo\'s file, and the old file can be put back', () async {
    // Changes a photo's file on the server: use the throwaway demo library (see the top of this file).
    if (!(env['SNAPSHOTS_TEST_CHANGE_FILES'] == '1')) {
      markTestSkipped('Set SNAPSHOTS_TEST_CHANGE_FILES=1 (and use a throwaway demo library) to run this one.');
      return;
    }
    final feed = Feed(api, const {'archived': 'hide', 'stacks': true}, pageSize: 60);
    await feed.loadMore();
    final a = feed.items.firstWhere((x) => x.kind == 'photo' && RegExp(r'\.jpe?g$', caseSensitive: false).hasMatch(x.filename) && x.width != x.height);
    await api.post('/api/assets/${a.id}/edits', {'edits': {'rotate': 90}});
    final turned = await api.post('/api/assets/${a.id}/apply-edits', <String, dynamic>{}) as Map;
    expect([turned['width'], turned['height']], [a.height, a.width]); // the file itself is turned
    expect(turned['edited'], false);                                  // nothing left to apply twice
    expect((turned['file_backups'] as List), isNotEmpty);             // the old file is kept
    final back = await api.post('/api/assets/${a.id}/restore-file', <String, dynamic>{}) as Map;
    expect([back['width'], back['height']], [a.width, a.height]);     // and put back, exactly as it was
  }, skip: skip);

  test('albums, favourites and search', () async {
    final albums = [for (final j in (await api.get('/api/albums'))['albums'] as List) Album(Map<String, dynamic>.from(j as Map))];
    final full = albums.where((a) => a.count > 0).firstOrNull;
    if (full == null) {
      markTestSkipped('This server has no album with photos in it: use the demo library (see the top of this file).');
      return;
    }
    final feed = Feed(api, {'album': full.id});
    await feed.loadMore();
    expect(feed.items.length, full.count);

    final one = feed.items.first;
    await api.post('/api/favorites', {'ids': [one.id], 'value': !one.favorite});
    final again = Asset(Map<String, dynamic>.from(await api.get('/api/assets/${one.id}') as Map));
    expect(again.favorite, !one.favorite);
    await api.post('/api/favorites', {'ids': [one.id], 'value': one.favorite});

    final s = await api.get('/api/search', query: {'q': '${one.takenAt.year}'});
    expect(s['words'], greaterThan(0));
  }, skip: skip);

  test('backup: check by SHA-1, upload, duplicate, trash and restore', () async {
    // A small, unique JPEG-named file the server accepts (it reads the extension).
    final dir = await Directory.systemTemp.createTemp('snap');
    final f = File('${dir.path}/IMG_20200102_030405.jpg');
    await f.writeAsBytes(_tinyJpeg(Random().nextInt(1 << 30)));
    final hash = (await sha1.bind(f.openRead()).first).toString();

    var have = (await api.post('/api/upload/check', {'sha1': [hash]}))['have'] as List;
    expect(have, isEmpty);

    Future<Map> upload() async {
      final r = await api.dio.post('/api/upload',
          data: FormData.fromMap({'files': await MultipartFile.fromFile(f.path, filename: 'IMG_20200102_030405.jpg')}));
      return (r.data['results'] as List).first as Map;
    }

    final first = await upload();
    expect(first['status'], 'added');
    have = (await api.post('/api/upload/check', {'sha1': [hash]}))['have'] as List;
    expect(have, [hash]);
    final second = await upload();
    expect(second['status'], 'duplicate');
    expect(second['id'], first['id']);

    final id = first['id'] as int;
    final a = Asset(Map<String, dynamic>.from(await api.get('/api/assets/$id') as Map));
    expect(a.takenAt, DateTime(2020, 1, 2, 3, 4, 5), reason: 'the date comes from the file name');

    await api.post('/api/trash', {'ids': [id]});
    final trash = Feed(api, const {'trashed': true});
    await trash.loadMore();
    expect(trash.items.map((x) => x.id), contains(id));
    await api.post('/api/trash/restore', {'ids': [id]});
    await dir.delete(recursive: true);
  }, skip: skip);

  // Also needs SNAPSHOTS_TEST_LIBRARY: the demo library's folder on this machine (the test deletes the
  // file it uploaded from it, as someone might in Windows).
  final library = env['SNAPSHOTS_TEST_LIBRARY'];
  test('free up space and the backup go by what is on the PC\'s disk, not its records', () async {
    final dir = await Directory.systemTemp.createTemp('snap');
    final f = File('${dir.path}/IMG_20190506_070809.jpg');
    await f.writeAsBytes(_tinyJpeg(Random().nextInt(1 << 30)));
    final hash = (await sha1.bind(f.openRead()).first).toString();
    Future<Map> upload() async {
      final r = await api.dio.post('/api/upload',
          data: FormData.fromMap({'files': await MultipartFile.fromFile(f.path, filename: 'IMG_20190506_070809.jpg')}));
      return (r.data['results'] as List).first as Map;
    }

    expect(await LibraryCheck.keptOnDisk(api, [hash]), isEmpty);
    final first = await upload();
    expect(first['status'], 'added');
    expect(await LibraryCheck.keptOnDisk(api, [hash]), {hash});
    expect(await LibraryCheck.lost(api, [hash]), isEmpty);

    // In the trash: sent, but not safe to remove from the phone.
    await api.post('/api/trash', {'ids': [first['id']]});
    expect(await LibraryCheck.keptOnDisk(api, [hash]), isEmpty);
    expect(await LibraryCheck.lost(api, [hash]), isEmpty);
    await api.post('/api/trash/restore', {'ids': [first['id']]});

    // The file is deleted on the PC. Its record stays, and no scan has run.
    final stored = Directory(library!).listSync(recursive: true).whereType<File>().where((x) => x.path.endsWith('IMG_20190506_070809.jpg'));
    expect(stored.length, 1);
    stored.single.deleteSync();
    expect(await LibraryCheck.keptOnDisk(api, [hash]), isEmpty, reason: 'the phone keeps its copy');
    expect(await LibraryCheck.lost(api, [hash]), {hash}, reason: 'the backup sends it again');

    final again = await upload();
    expect(again['status'], 'added', reason: 'not thrown away as a duplicate');
    expect(again['id'], first['id'], reason: 'the same item carries on');
    expect(await LibraryCheck.keptOnDisk(api, [hash]), {hash});
    await dir.delete(recursive: true);
  }, skip: skip ?? (library == null ? 'Set SNAPSHOTS_TEST_LIBRARY to the demo library folder' : null));
}

/// A valid 1×1 JPEG with a comment that makes each one different.
List<int> _tinyJpeg(int seed) {
  const head = [0xFF, 0xD8];
  final comment = 'snapshots-test-$seed'.codeUnits;
  final com = [0xFF, 0xFE, 0, comment.length + 2, ...comment];
  const body = [
    0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C,
    0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12, 0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
    0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27,
    0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01,
    0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10,
    0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D, 0x01, 0x02, 0x03, 0x00,
    0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
    0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A,
    0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
    0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
    0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA,
    0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
    0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA,
    0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD3, 0xFF, 0xD9,
  ];
  return [...head, ...com, ...body];
}
