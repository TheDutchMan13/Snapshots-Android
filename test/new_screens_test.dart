// Draws the screens added in 0.2 against a real Snapshots server and saves them as PNGs, to look at.
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

  Future<void> back(WidgetTester tester) async {
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(tester, rounds: 3);
  }

  testWidgets('more pages: activity, highlights, calendar, events, review, pets', (tester) async {
    await start(tester);
    await tester.tap(find.text('More'));
    await settle(tester);
    await shot(tester, '20-more');
    for (final (name, file) in [('Calendar', '21-calendar'), ('Events', '22-events'), ('Year in review', '23-review'), ('Pets', '24-pets'), ('Activity', '25-activity'), ('Highlights', '26-highlights')]) {
      await tester.tap(find.text(name).first);
      await settle(tester);
      await shot(tester, file);
      if (name == 'Year in review') {
        await tester.tap(find.text('2025'));
        await settle(tester, rounds: 12);
        await shot(tester, '23b-review-2025');
        await back(tester);
      }
      if (name == 'Calendar') {
        await tester.tap(find.text('2025'));
        await settle(tester);
        await shot(tester, '21a-calendar-2025');
        await tester.tap(find.byType(InkWell).at(20));
        await settle(tester);
        await shot(tester, '21b-calendar-tap');
        await back(tester);
      }
      await back(tester);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 70));
  }, skip: skip != null);

  testWidgets('filter, viewer details, marks, edit', (tester) async {
    await start(tester);
    await tester.tap(find.byTooltip('Filter'));
    await settle(tester);
    await shot(tester, '30-filter');
    await tester.tap(find.text('Portrait'));
    await tester.pump();
    await tester.tap(find.text('Show'));
    await settle(tester);
    await shot(tester, '31-filtered');
    await tester.tap(find.byTooltip(RegExp('^Filter')));
    await settle(tester);
    await tester.tap(find.text('Show everything'));
    await tester.pump();
    await tester.tap(find.text('Show'));
    await settle(tester);

    // A photo (Highlights has no videos).
    await tester.tap(find.text('More'));
    await settle(tester);
    await tester.tap(find.text('Highlights'));
    await settle(tester);
    await tester.tap(find.byType(GestureDetector).at(0));
    await settle(tester, rounds: 12);
    await tester.tap(find.byTooltip('Details'));
    await settle(tester);
    await shot(tester, '32-details');
    await tester.tap(find.byIcon(Icons.star_outline));
    await settle(tester);
    await shot(tester, '33-marks');
    await tester.tap(find.byTooltip('4 stars'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await settle(tester);
    await shot(tester, '34-details-after-marks');
    await tester.tapAt(const Offset(200, 100));
    await settle(tester, rounds: 3);
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await settle(tester, rounds: 3);
    await shot(tester, '35-viewer-menu');
    await tester.tap(find.text('Edit'));
    await settle(tester, rounds: 12);
    await shot(tester, '36-editor');
    await tester.tap(find.text('Turn'));
    await tester.tap(find.text('Square'));
    await settle(tester, rounds: 4);
    await shot(tester, '37-editor-turned-square');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 70));
  }, skip: skip != null);

  testWidgets('smart album, comments, selection menu', (tester) async {
    await start(tester);
    await tester.tap(find.text('Albums'));
    await settle(tester);
    await tester.tap(find.byTooltip('New album'));
    await settle(tester, rounds: 3);
    await shot(tester, '40-new-album-menu');
    await tester.tap(find.text('New smart album'));
    await settle(tester);
    await shot(tester, '41-smart-album');
    await back(tester);
    await tester.tap(find.text('Rome 2019'));
    await settle(tester);
    await tester.tap(find.byType(PopupMenuButton<VoidCallback>).first);
    await settle(tester, rounds: 3);
    await tester.tap(find.text('Comments'));
    await settle(tester);
    await shot(tester, '42-comments');
    await tester.enterText(find.byType(TextField), 'What a trip!');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    await shot(tester, '43-comment-sent');
    await tester.tapAt(const Offset(200, 100));
    await settle(tester, rounds: 3);
    final tiles = find.byType(GestureDetector);
    await tester.longPress(tiles.at(2));
    await settle(tester, rounds: 2);
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await settle(tester, rounds: 3);
    await shot(tester, '44-selection-menu');
    await tester.tap(find.text('Change date'));
    await settle(tester, rounds: 3);
    await shot(tester, '45-change-date');
    await tester.tap(find.text('Move by some hours'));
    await settle(tester, rounds: 3);
    await shot(tester, '46-shift');
  }, skip: skip != null);
}
