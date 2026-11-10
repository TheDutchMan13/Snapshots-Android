import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:snapshots_app/api/client.dart';
import 'package:snapshots_app/backup/backup_service.dart';
import 'package:snapshots_app/state/feed.dart';
import 'package:snapshots_app/state/session.dart';
import 'package:snapshots_app/ui/media.dart';
import 'package:snapshots_app/ui/search_screen.dart';

/// Answers every request with [body] after a short wait, and counts the paths asked for.
class Slow implements HttpClientAdapter {
  Slow(this.body, {this.type = 'application/json'});

  final String Function(RequestOptions o) body;
  final String type;
  final asked = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? b, Future<void>? c) async {
    asked.add(o.path);
    // The search counts come slowly, as on a big library.
    await Future<void>.delayed(Duration(milliseconds: o.path == '/api/search' ? 200 : 30));
    return ResponseBody.fromString(body(o), 200, headers: {
      'content-type': [type],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// A tiny Snapshots on this machine that remembers the cookies it was sent.
Future<(HttpServer, List<String?>)> pc() async {
  final srv = await HttpServer.bind('127.0.0.1', 0);
  final cookies = <String?>[];
  srv.listen((r) async {
    cookies.add(r.headers.value('cookie'));
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode({'needs_setup': false, 'version': '1'}));
    await r.response.close();
  });
  return (srv, cookies);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('session', () {
    late int forgotten;
    setUp(() {
      HttpOverrides.global = null; // real sockets, to 127.0.0.1 only
      diskImageCache = false;
      forgotten = 0;
      Session.forgetBackup = () async => forgotten++;
    });

    test('connecting to another PC from the sign-in screen starts the backup record over', () async {
      final (a, _) = await pc();
      final (b, _) = await pc();
      final serverA = 'http://127.0.0.1:${a.port}';
      FlutterSecureStorage.setMockInitialValues({'server': serverA});
      final s = Session();
      await s.load();

      await s.checkServer('127.0.0.1:${a.port}'); // the same PC again
      expect(forgotten, 0);
      await s.checkServer('127.0.0.1:${b.port}'); // "Use another PC" on the sign-in screen
      expect(forgotten, 1);
      await s.checkServer('127.0.0.1:${b.port}/');
      expect(forgotten, 1);

      // After "Use another PC" in More (which forgets the stored address) it still notices.
      await s.changeServer();
      await s.checkServer('127.0.0.1:${a.port}');
      expect(forgotten, 2);
      await a.close(force: true);
      await b.close(force: true);
    });

    test("one PC's device cookie is never sent to another", () async {
      final (a, cookiesA) = await pc();
      final (b, cookiesB) = await pc();
      final serverA = 'http://127.0.0.1:${a.port}';
      // As saved by 0.1.1: one cookie, for the server stored next to it.
      FlutterSecureStorage.setMockInitialValues({'server': serverA, 'token': 't', 'user': '1\n0\nhans', 'device': 'COOKIE-A'});
      final s = Session();
      await s.load();
      await s.api!.get('/api/auth/state');
      expect(cookiesA.last, 'snapshots_device=COOKIE-A');

      await s.changeServer();
      await s.checkServer('127.0.0.1:${b.port}');
      await s.api!.get('/api/auth/state');
      expect(cookiesB.last, isNull);

      // Back to the first PC: its own cookie again.
      await s.checkServer('127.0.0.1:${a.port}');
      await s.api!.get('/api/auth/state');
      expect(cookiesA.last, 'snapshots_device=COOKIE-A');
      await a.close(force: true);
      await b.close(force: true);
    });
  });

  test('plain http outside Tailscale is flagged', () {
    expect(Api.unencrypted('192.168.1.20:8000'), isTrue);
    expect(Api.unencrypted('http://mypc.local:8000'), isTrue);
    expect(Api.unencrypted('100.101.102.103:8000'), isFalse);
    expect(Api.unencrypted('100.64.0.1'), isFalse);
    expect(Api.unencrypted('100.128.0.1'), isTrue); // outside 100.64.0.0/10
    expect(Api.unencrypted('mypc.tail1234.ts.net:8000'), isFalse);
    expect(Api.unencrypted('https://photos.example.com'), isFalse);
    expect(Api.unencrypted(''), isFalse);
  });

  test('"Upload failed" from the PC is tried again; a refused file stays refused', () {
    expect(BackupRun.uploadOutcome({'status': 'rejected', 'reason': 'Upload failed: [Errno 28] No space left'}), 'retry');
    expect(BackupRun.uploadOutcome({'status': 'rejected', 'reason': 'Unsupported file type'}), 'rejected');
    expect(BackupRun.uploadOutcome({}), 'rejected');
    expect(BackupRun.uploadOutcome({'status': 'added', 'id': 4}), 'added');
    expect(BackupRun.uploadOutcome({'status': 'duplicate'}), 'duplicate');
  });

  test('a feed closed while loading drops the answer quietly', () async {
    final api = Api(server: 'pc', token: 't')..dio.httpClientAdapter = Slow((_) => jsonEncode({'items': [], 'next': null}));
    final f = Feed(api, const {'q': 'cat'});
    final loading = f.loadMore();
    f.dispose();
    await loading; // used to throw "A Feed was used after being disposed"
  });

  test('an answer that is not Snapshots shows an error instead of a spinner forever', () async {
    final api = Api(server: 'pc', token: 't')..dio.httpClientAdapter = Slow((_) => '<html>Sign in to the Wi-Fi</html>', type: 'text/html');
    final f = Feed(api, const {});
    await f.loadMore();
    expect(f.loading, isFalse);
    expect(f.error, isNotNull);
    expect(f.error, contains('sign in'));
  });

  test('search mode from the counts', () {
    expect(searchMode({'words': 3, 'content': 5, 'mixed': 7}), 'mix');
    expect(searchMode({'words': 0, 'content': 5, 'mixed': 5}), 'look');
    expect(searchMode({'words': 3, 'content': 0}), 'words');
    expect(searchMode({'words': 0, 'content': 0}), 'words');
  });

  testWidgets('a search loads one grid, in the mode the counts call for', (tester) async {
    diskImageCache = false;
    final fake = Slow((o) => o.path == '/api/search'
        ? jsonEncode({'words': 2, 'content': 4, 'mixed': 5, 'content_enabled': true, 'content_ready': true})
        : o.path == '/api/assets'
            ? jsonEncode({'items': [], 'next': null})
            : jsonEncode({'places': [], 'events': [], 'tags': []}));
    final api = Api(server: 'pc', token: 't')..dio.httpClientAdapter = fake;
    final session = Session()
      ..loaded = true
      ..api = api;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: session,
      child: const MaterialApp(home: SearchScreen()),
    ));
    await tester.enterText(find.byType(TextField), 'dog');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    // The fake server's wait runs on the test's clock or the real one, depending on where the
    // request started: let both run.
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(fake.asked.where((p) => p == '/api/assets').length, 1);
    expect(find.text('Best (5)'), findsOneWidget);
    expect(find.text('Nothing found for "dog".'), findsOneWidget);
  });
}
