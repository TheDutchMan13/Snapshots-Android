// The code that sends the phone's photos to the PC, and the code that removes them from the phone.
// Everything here runs against a pretend PC (FakePc), a notebook in memory (MemoryDb) and files in a
// temporary folder: no Android, no network.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:snapshots_app/api/client.dart';
import 'package:snapshots_app/backup/backup_db.dart';
import 'package:snapshots_app/backup/backup_service.dart';
import 'package:snapshots_app/backup/free_space.dart';
import 'package:snapshots_app/backup/library_check.dart';
import 'package:snapshots_app/backup/phone_item.dart';

/// A pretend Snapshots. [onDisk] is what its library really holds; [records] is what it has records of
/// (an older Snapshots answered from those). [trash] holds files that are there but in the trash.
class FakePc implements HttpClientAdapter {
  FakePc({this.verifies = true, this.knowsKept = true});

  bool verifies;
  bool knowsKept;
  bool offline = false;
  final onDisk = <String>{};
  final records = <String>{};
  final trash = <String>{};
  final checks = <Map<String, dynamic>>[];
  final uploads = <String>[];

  /// What to answer the next uploads with instead of storing them: an HTTP status, or a result map.
  final uploadAnswers = <Object>[];
  int _nextId = 100;

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    final sent = body == null ? <int>[] : [for (final chunk in await body.toList()) ...chunk];
    if (offline) throw DioException.connectionError(requestOptions: o, reason: 'offline');
    if (o.path == '/api/upload/check') {
      final q = Map<String, dynamic>.from(jsonDecode(utf8.decode(sent)) as Map);
      checks.add(q);
      final asked = [for (final h in q['sha1'] as List) '$h'];
      final kept = q['kept'] == true && knowsKept;
      final source = verifies ? onDisk : records.union(onDisk);
      final have = [for (final h in asked) if (source.contains(h) && !(kept && trash.contains(h))) h];
      return _json(200, {'have': have, if (knowsKept) 'kept': q['kept'] == true, if (verifies) 'verified': true});
    }
    if (o.path == '/api/upload') {
      final name = (o.data as FormData).files.first.value.filename ?? '';
      uploads.add(name);
      if (uploadAnswers.isNotEmpty) {
        final a = uploadAnswers.removeAt(0);
        if (a is int) return _json(a, {'detail': 'Refused ($a).'});
        return _json(200, {'results': [a]});
      }
      // The bytes of the one file are between the multipart headers and the closing boundary.
      final text = latin1.decode(sent);
      final start = text.indexOf('\r\n\r\n') + 4;
      final end = text.lastIndexOf('\r\n--');
      final hash = sha1.convert(latin1.encode(text.substring(start, end))).toString();
      if (onDisk.contains(hash)) return _json(200, {'results': [{'name': name, 'status': 'duplicate', 'id': 7}]});
      onDisk.add(hash);
      records.add(hash);
      return _json(200, {'results': [{'name': name, 'status': 'added', 'id': _nextId++}]});
    }
    if (o.path.startsWith('/api/assets/')) return _json(200, {'taken_at': '2020-01-01T10:00:00'});
    return _json(404, {'detail': 'Not found'});
  }

  ResponseBody _json(int status, Object data) => ResponseBody.fromString(jsonEncode(data), status, headers: {
        'content-type': ['application/json'],
      });

  @override
  void close({bool force = false}) {}
}

/// The backup's notebook, in memory.
class MemoryDb implements BackupDb {
  final rows = <String, Map<String, Object?>>{};

  String? statusOf(String id) => rows[id]?['status'] as String?;

  @override
  Future<Map<String, ({int modified, String status, String? sha1})>> known() async => {
        for (final e in rows.entries)
          e.key: (modified: e.value['modified'] as int, status: e.value['status'] as String, sha1: e.value['sha1'] as String?)
      };

  @override
  Future<void> put(String localId, int modified, String status,
      {String? sha1, int? serverId, String? reason, String? name}) async {
    rows[localId] = {'modified': modified, 'status': status, 'sha1': sha1, 'server_id': serverId, 'reason': reason, 'name': name};
  }

  @override
  Future<int> count(String status) async => rows.values.where((r) => r['status'] == status).length;

  @override
  Future<List<({String name, String reason})>> rejected({int limit = 50}) async => [
        for (final r in rows.values)
          if (r['status'] == 'rejected') (name: '${r['name'] ?? ''}', reason: '${r['reason'] ?? ''}')
      ];

  @override
  Future<List<({String localId, int modified, String sha1})>> sent() async => [
        for (final e in rows.entries)
          if (e.value['status'] == 'sent' && e.value['sha1'] != null)
            (localId: e.key, modified: e.value['modified'] as int, sha1: e.value['sha1'] as String)
      ];

  @override
  Future<void> markFreed(List<String> localIds) async {
    for (final id in localIds) {
      rows[id]?['status'] = 'freed';
    }
  }

  @override
  Future<int> sendAgain(Iterable<String> sha1s) async {
    final lost = sha1s.toSet();
    var n = 0;
    for (final r in rows.values) {
      if (r['status'] == 'sent' && lost.contains(r['sha1'])) {
        r['status'] = 'hashed';
        r['server_id'] = null;
        n++;
      }
    }
    return n;
  }

  @override
  Future<void> clear() async => rows.clear();

  @override
  Future<void> retryRejected() async => rows.removeWhere((_, r) => r['status'] == 'rejected');
}

/// A photo on the pretend phone: a real file in a temporary folder.
class FileItem implements PhoneItem {
  FileItem(this.id, this._file, {this.modified = 1000, this.readable = true});

  final File _file;
  bool readable;

  @override
  final String id;

  @override
  int modified;

  @override
  DateTime get created => DateTime(2024, 5, 1, 10);

  @override
  Future<String> name() async => '$id.jpg';

  @override
  Future<File?> file() async => readable ? _file : null;

  String get hash => sha1.convert(_file.readAsBytesSync()).toString();
}

String hashOf(int n) => sha1.convert(utf8.encode('photo $n')).toString();

void main() {
  late Directory tmp;
  late FakePc pc;
  late Api api;
  late MemoryDb db;

  FileItem photo(String id, {String? content, int modified = 1000}) {
    final f = File('${tmp.path}/$id.jpg')..writeAsStringSync(content ?? 'the picture $id');
    return FileItem(id, f, modified: modified);
  }

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    tmp = Directory.systemTemp.createTempSync('snapshots-backup-test');
    pc = FakePc();
    api = Api(server: 'pc:8080', token: 't')..dio.httpClientAdapter = pc;
    db = MemoryDb();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('asking the PC what it really has', () {
    test('only files the PC saw on its disk, outside the trash, count as kept', () async {
      pc.onDisk.addAll([hashOf(1), hashOf(2)]);
      pc.records.addAll([hashOf(1), hashOf(2), hashOf(3)]); // 3: a record whose file is gone
      pc.trash.add(hashOf(2));
      final kept = await LibraryCheck.keptOnDisk(api, [hashOf(1), hashOf(2), hashOf(3), hashOf(4)]);
      expect(kept, {hashOf(1)});
      expect(pc.checks.single['kept'], true);
    });

    test('a Snapshots that answers from its records is not trusted', () async {
      pc
        ..verifies = false
        ..records.add(hashOf(1));
      await expectLater(LibraryCheck.keptOnDisk(api, [hashOf(1)]),
          throwsA(isA<ApiError>().having((e) => e.message, 'message', contains('Update Snapshots on the PC'))));
    });

    test('nor is one that does not know about the trash', () async {
      pc
        ..knowsKept = false
        ..onDisk.add(hashOf(1));
      await expectLater(LibraryCheck.keptOnDisk(api, [hashOf(1)]), throwsA(isA<ApiError>()));
    });

    test('a thousand at a time, and an answer about something else is ignored', () async {
      final all = [for (var i = 0; i < 2500; i++) hashOf(i)];
      pc.onDisk.addAll(all.take(2400));
      final kept = await LibraryCheck.keptOnDisk(api, all);
      expect(kept.length, 2400);
      expect([for (final c in pc.checks) (c['sha1'] as List).length], [1000, 1000, 500]);

      final liar = Api(server: 'pc', token: 't')
        ..dio.httpClientAdapter = _Fixed({'have': [hashOf(1), hashOf(99)], 'kept': true, 'verified': true});
      expect(await LibraryCheck.keptOnDisk(liar, [hashOf(1)]), {hashOf(1)});
    });

    test('what the PC lost: sent before, not there now', () async {
      pc.onDisk.add(hashOf(1));
      pc.records.addAll([hashOf(1), hashOf(2)]);
      expect(await LibraryCheck.lost(api, [hashOf(1), hashOf(2)]), {hashOf(2)});
      pc.verifies = false; // an older Snapshots can't say, so nothing is called lost
      expect(await LibraryCheck.lost(api, [hashOf(1), hashOf(2)]), isNull);
    });
  });

  group('free up space', () {
    test('only photos still on the phone and unchanged since they were sent are considered', () {
      final sent = [
        (localId: 'a', modified: 10, sha1: hashOf(1)),
        (localId: 'b', modified: 10, sha1: hashOf(2)), // edited on the phone since
        (localId: 'c', modified: 10, sha1: hashOf(3)), // no longer on the phone
        (localId: 'd', modified: 0, sha1: hashOf(4)),
      ];
      final onPhone = {'a': 10, 'b': 11, 'd': 0};
      expect(FreeSpace.unchangedSums(sent, (id) => onPhone[id]), {'a': hashOf(1), 'd': hashOf(4)});
    });

    Future<({int gone, int held})> remove(List<String> ids, Map<String, String> sums,
        {Set<String> changed = const {}, bool sayNo = false, List<String>? deleted, List<String>? freed, int perStep = 300}) {
      return FreeSpace.removeChecked(
        api: api,
        ids: ids,
        sums: sums,
        perStep: perStep,
        unchanged: (id) async => !changed.contains(id),
        delete: (part) async {
          if (sayNo) return [];
          deleted?.addAll(part);
          return part;
        },
        freed: (part) async => freed?.addAll(part),
      );
    }

    test('a photo the PC lost after the list was made stays on the phone', () async {
      final sums = {'a': hashOf(1), 'b': hashOf(2), 'c': hashOf(3)};
      pc.onDisk.addAll([hashOf(1), hashOf(3)]); // b's file was deleted on the PC a moment ago
      pc.records.addAll(sums.values);
      final deleted = <String>[], freed = <String>[];
      final r = await remove(['a', 'b', 'c'], sums, deleted: deleted, freed: freed);
      expect(r, (gone: 2, held: 1));
      expect(deleted, ['a', 'c']);
      expect(freed, ['a', 'c']);
    });

    test('a photo put in the PC\'s trash, or changed on the phone, stays', () async {
      final sums = {'a': hashOf(1), 'b': hashOf(2), 'c': hashOf(3)};
      pc.onDisk.addAll(sums.values);
      pc.trash.add(hashOf(1));
      final deleted = <String>[];
      final r = await remove(['a', 'b', 'c'], sums, changed: {'b'}, deleted: deleted);
      expect(r, (gone: 1, held: 2));
      expect(deleted, ['c']);
    });

    test('an older Snapshots, or no connection: nothing is removed', () async {
      final sums = {'a': hashOf(1)};
      pc
        ..verifies = false
        ..records.add(hashOf(1));
      final deleted = <String>[];
      await expectLater(remove(['a'], sums, deleted: deleted), throwsA(isA<ApiError>()));
      pc
        ..verifies = true
        ..onDisk.add(hashOf(1))
        ..offline = true;
      await expectLater(remove(['a'], sums, deleted: deleted), throwsA(isA<ApiError>()));
      expect(deleted, isEmpty);
    });

    test('saying no to Android\'s question removes and notes nothing', () async {
      final sums = {'a': hashOf(1), 'b': hashOf(2)};
      pc.onDisk.addAll(sums.values);
      final freed = <String>[];
      expect(await remove(['a', 'b'], sums, sayNo: true, freed: freed, perStep: 1), (gone: 0, held: 0));
      expect(freed, isEmpty);
      expect(pc.checks.length, 1); // it stopped at the first no
    });

    test('each part is checked right before it is removed, and unknown ids are left alone', () async {
      final sums = {'a': hashOf(1), 'b': hashOf(2)};
      pc.onDisk.addAll(sums.values);
      final deleted = <String>[];
      final r = await remove(['a', 'b', 'x'], sums, deleted: deleted, perStep: 1);
      expect(r, (gone: 2, held: 1));
      expect(deleted, ['a', 'b']);
      expect([for (final c in pc.checks) c['sha1']], [
        [hashOf(1)],
        [hashOf(2)]
      ]);
    });
  });

  group('the backup', () {
    BackupRun run() => BackupRun.withParts(api: api, db: db);

    test('a new photo is sent once, and not again', () async {
      final a = photo('a');
      expect(await run().sendAll([a]), 'Done: 1 sent.');
      expect(pc.uploads, ['a.jpg']);
      expect(pc.onDisk, {a.hash});
      expect(db.rows['a'], containsPair('status', 'sent'));
      expect(db.rows['a'], containsPair('sha1', a.hash));
      expect(db.rows['a'], containsPair('server_id', 100));

      expect(await run().sendAll([a]), 'Everything is backed up (1 on this phone).');
      expect(pc.uploads.length, 1);
    });

    test('a photo the PC already has is not sent', () async {
      final a = photo('a');
      pc.onDisk.add(a.hash);
      expect(await run().sendAll([a]), 'Done: 1 were already in Snapshots.');
      expect(pc.uploads, isEmpty);
      expect(db.statusOf('a'), 'sent');
    });

    test('a record on the PC without its file does not count: the photo is sent', () async {
      final a = photo('a');
      pc.records.add(a.hash); // the PC has a record, and the file is gone
      expect(await run().sendAll([a]), 'Done: 1 sent.');
      expect(pc.uploads, ['a.jpg']);
    });

    test('a photo edited on the phone is sent again', () async {
      final a = photo('a');
      await run().sendAll([a]);
      File('${tmp.path}/a.jpg').writeAsStringSync('the picture, edited');
      a.modified = 2000;
      expect(await run().sendAll([a]), 'Done: 1 sent.');
      expect(pc.uploads.length, 2);
      expect(db.rows['a'], containsPair('sha1', a.hash));
      expect(pc.onDisk.length, 2);
    });

    test('a file that can\'t be read is tried again, and the others go on', () async {
      final a = photo('a')..readable = false;
      final b = photo('b');
      expect(await run().sendAll([a, b]), "Done: 1 sent, 1 couldn't be read on the phone and will be tried again.");
      expect(db.statusOf('a'), 'hashed'); // not given up on
      expect(db.statusOf('b'), 'sent');
      expect(await db.count('rejected'), 0);
      // Still unreadable at the next run: asked about again, and noted again.
      expect(await run().sendAll([a, b]), "Done: 1 couldn't be read on the phone and will be tried again.");
      a.readable = true; // the permission came back
      expect(await run().sendAll([a, b]), 'Done: 1 sent.');
      expect(db.statusOf('a'), 'sent');
      expect(pc.uploads, ['b.jpg', 'a.jpg']);
    });

    test('a file the PC turns away is noted, and the others go on', () async {
      final a = photo('a'), b = photo('b');
      pc.uploadAnswers.add({'name': 'a.jpg', 'status': 'rejected', 'reason': 'Unsupported file type'});
      expect(await run().sendAll([a, b]), "Done: 1 sent, 1 couldn't be backed up.");
      expect(db.rows['a'], containsPair('reason', 'Unsupported file type'));
      expect(db.statusOf('b'), 'sent');

      final c = photo('c'), d = photo('d');
      pc.uploadAnswers.add(413); // too big for the PC's limit
      expect(await run().sendAll([c, d]), "Done: 1 sent, 1 couldn't be backed up.");
      expect(db.statusOf('c'), 'rejected');
      expect(db.statusOf('d'), 'sent');
    });

    test('an answer that only means "not now" stops the run and keeps the file for next time', () async {
      for (final code in [408, 423, 425]) {
        final a = photo('a$code'), b = photo('b$code');
        pc.uploadAnswers.add(code);
        await expectLater(run().sendAll([a, b]), throwsA(isA<ApiError>().having((e) => e.status, 'status', code)));
        expect(db.statusOf(a.id), 'hashed');
        expect(await db.count('rejected'), 0);
        expect(await run().sendAll([a, b]), 'Done: 2 sent.');
      }
    });

    test('when the PC could not save a file, it is tried again next time', () async {
      final a = photo('a'), b = photo('b');
      pc.uploadAnswers.add({'name': 'a.jpg', 'status': 'rejected', 'reason': 'Upload failed: [Errno 28] No space left'});
      expect(await run().sendAll([a, b]), "Done: 1 sent, 1 couldn't be saved on the PC and will be tried again.");
      expect(db.statusOf('a'), 'hashed');
      expect(await run().sendAll([a, b]), 'Done: 1 sent.');
      expect(db.statusOf('a'), 'sent');
      expect(pc.uploads, ['a.jpg', 'b.jpg', 'a.jpg']);
    });

    test('three such failures in a row stop the run; a full or missing drive stops it at once', () async {
      final items = [for (final id in ['a', 'b', 'c', 'd']) photo(id)];
      for (var i = 0; i < 3; i++) {
        pc.uploadAnswers.add({'status': 'rejected', 'reason': 'Upload failed: disk'});
      }
      await expectLater(run().sendAll(items), throwsA(isA<ApiError>()));
      expect(pc.uploads.length, 3);
      expect([for (final i in items) db.statusOf(i.id)], ['hashed', 'hashed', 'hashed', 'hashed']);

      pc.uploads.clear();
      pc.uploadAnswers.add(507); // the library drive is full
      await expectLater(run().sendAll(items), throwsA(isA<ApiError>().having((e) => e.status, 'status', 507)));
      expect(pc.uploads.length, 1);
      expect(db.statusOf('a'), 'hashed'); // not given up on
      expect(await run().sendAll(items), 'Done: 4 sent.');
    });

    test('a lost connection leaves nothing marked as sent', () async {
      final a = photo('a');
      pc.offline = true;
      await expectLater(run().sendAll([a]), throwsA(isA<ApiError>()));
      expect(db.statusOf('a'), 'hashed');
      pc.offline = false;
      expect(await run().sendAll([a]), 'Done: 1 sent.');
    });

    test('what needs looking at', () {
      expect(BackupRun.needsWork(null, 5), true);
      expect(BackupRun.needsWork((modified: 5, status: 'sent', sha1: 'x'), 5), false);
      expect(BackupRun.needsWork((modified: 5, status: 'rejected', sha1: null), 5), false);
      expect(BackupRun.needsWork((modified: 5, status: 'hashed', sha1: 'x'), 5), true);
      expect(BackupRun.needsWork((modified: 5, status: 'sent', sha1: 'x'), 6), true);
      expect(BackupRun.needsWork((modified: 5, status: 'freed', sha1: 'x'), 5), true);
    });
  });

  group('photos the PC lost are sent again', () {
    BackupRun run() => BackupRun.withParts(api: api, db: db);

    test('the files were deleted on the PC: the next backup sends them again', () async {
      final a = photo('a'), b = photo('b');
      await run().sendAll([a, b]);
      pc.onDisk.remove(a.hash); // deleted on the PC; its record stays
      final again = run();
      expect(await again.recheckSent(force: true), 1);
      expect(db.statusOf('a'), 'hashed');
      expect(db.statusOf('b'), 'sent');
      expect(await again.sendAll([a, b]), 'Done: 1 sent, 1 was no longer on the PC and is sent again.');
      expect(pc.onDisk, {a.hash, b.hash});
      expect(db.statusOf('a'), 'sent');
    });

    test('an older Snapshots can\'t say what it lost, so nothing changes', () async {
      final a = photo('a');
      await run().sendAll([a]);
      pc
        ..verifies = false
        ..onDisk.clear();
      expect(await run().recheckSent(force: true), 0);
      expect(db.statusOf('a'), 'sent');
    });

    test('the background run asks once a day; "Back up now" always asks', () async {
      final a = photo('a');
      await run().sendAll([a]);
      pc.checks.clear();
      expect(await run().recheckSent(), 0);
      expect(pc.checks.length, 1);
      pc.onDisk.clear();
      expect(await run().recheckSent(), 0); // asked a moment ago
      expect(pc.checks.length, 1);
      expect(await run().recheckSent(force: true), 1);
    });

    test('a photo already removed from the phone is left as it is', () async {
      final a = photo('a');
      await run().sendAll([a]);
      await db.markFreed(['a']);
      pc.onDisk.clear();
      expect(await run().recheckSent(force: true), 0);
      expect(db.statusOf('a'), 'freed');
    });

    test('no connection: the check fails loudly and nothing is changed', () async {
      final a = photo('a');
      await run().sendAll([a]);
      pc.offline = true;
      await expectLater(run().recheckSent(force: true), throwsA(isA<ApiError>()));
      expect(db.statusOf('a'), 'sent');
    });
  });
}

/// Always gives the same answer.
class _Fixed implements HttpClientAdapter {
  _Fixed(this.answer);

  final Object answer;

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    await body?.drain<void>();
    return ResponseBody.fromString(jsonEncode(answer), 200, headers: {
      'content-type': ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}
