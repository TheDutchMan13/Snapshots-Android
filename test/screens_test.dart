// Draws the main screens against a real Snapshots server and saves them as PNGs, to look at.
//   SNAPSHOTS_TEST_SERVER=127.0.0.1:8790 flutter test test/screens_test.dart --update-goldens
// The pictures land in test/shots/ (not kept in git).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:snapshots_app/api/client.dart';
import 'package:snapshots_app/main.dart';
import 'package:snapshots_app/state/session.dart';
import 'package:snapshots_app/ui/media.dart';

Future<void> _font(String family, List<String> files) async {
  final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/sdk/flutter'}/bin/cache/artifacts/material_fonts';
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(File('$fonts/$f').readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await loader.load();
}

void main() {
  final server = Platform.environment['SNAPSHOTS_TEST_SERVER'];
  final skip = server == null ? 'Set SNAPSHOTS_TEST_SERVER' : null;
  TestWidgetsFlutterBinding.ensureInitialized();
  late Session session;

  setUpAll(() async {
    if (server == null) return;
    HttpOverrides.global = null; // real network
    diskImageCache = false;
    await _font('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
    await _font('MaterialIcons', ['MaterialIcons-Regular.otf']);
  });

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> start(WidgetTester tester, {bool signedIn = true, Brightness b = Brightness.light}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    tester.platformDispatcher.platformBrightnessTestValue = b;
    addTearDown(tester.view.reset);
    session = Session()..loaded = true;
    if (signedIn) {
      await tester.runAsync(() async {
        final api = Api(server: server!);
        final r = await api.post('/api/auth/login', {'username': 'hans', 'password': 'demo password 1'});
        api.token = r['token'] as String;
        session.api = api;
        session.user = User.fromJson(Map<String, dynamic>.from(r['user'] as Map));
      });
    }
    await tester.pumpWidget(ChangeNotifierProvider.value(value: session, child: const SnapshotsApp()));
    await settle(tester);
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }

  testWidgets('sign in', (tester) async {
    await start(tester, signedIn: false);
    await shot(tester, '01-login');
  }, skip: skip != null);

  testWidgets('photos, albums, search, people, more', (tester) async {
    await start(tester);
    await shot(tester, '02-photos');

    await tester.tap(find.text('Albums'));
    await settle(tester);
    await shot(tester, '03-albums');
    // Whatever album the server has first: the test no longer depends on a particular demo album.
    final albums = await tester.runAsync(() => session.api!.get('/api/albums'));
    await tester.tap(find.text((albums['albums'] as List).first['name'] as String));
    await settle(tester);
    await shot(tester, '04-album');
    await tester.pageBack();
    await settle(tester, rounds: 3);

    await tester.tap(find.text('Search'));
    await settle(tester);
    await shot(tester, '05-explore');
    await tester.enterText(find.byType(TextField), '2026');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    await shot(tester, '06-search');

    await tester.tap(find.text('People'));
    await settle(tester);
    await shot(tester, '07-people');

    await tester.tap(find.text('More'));
    await settle(tester);
    await shot(tester, '08-more');
  }, skip: skip != null);

  testWidgets('viewer, details and selection', (tester) async {
    await start(tester, b: Brightness.dark);
    await shot(tester, '09-photos-dark');

    // Select two photos.
    final tiles = find.byType(GestureDetector);
    await tester.longPress(tiles.at(3));
    await tester.pump();
    await tester.tap(tiles.at(4));
    await settle(tester, rounds: 2);
    await shot(tester, '10-selected');
    await tester.tap(find.byTooltip('Done'));
    await settle(tester, rounds: 2);

    await tester.tap(tiles.at(3));
    await settle(tester, rounds: 12);
    await shot(tester, '11-viewer');
    await tester.tap(find.byTooltip('Details'));
    await settle(tester);
    await shot(tester, '12-details');
    // Let the viewer's timers finish before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }, skip: skip != null);
}
