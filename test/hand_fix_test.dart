// Draws the selection menu against a real Snapshots server (the throwaway demo library on 0.15.1 or newer)
// and checks that "Turn…" and "It's a pet…" are offered there, and that turning really turns.
//   SNAPSHOTS_TEST_SERVER=127.0.0.1:8790 SNAPSHOTS_TEST_CHANGE_FILES=1 flutter test test/hand_fix_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:snapshots_app/api/client.dart';
import 'package:snapshots_app/main.dart';
import 'package:snapshots_app/state/session.dart';
import 'package:snapshots_app/ui/albums_screen.dart';
import 'package:snapshots_app/ui/media.dart';

void main() {
  final env = Platform.environment;
  final server = env['SNAPSHOTS_TEST_SERVER'];
  final skip = server == null || env['SNAPSHOTS_TEST_CHANGE_FILES'] != '1'
      ? 'Set SNAPSHOTS_TEST_SERVER and SNAPSHOTS_TEST_CHANGE_FILES=1 (throwaway demo library)'
      : null;
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the selection menu offers Turn and It\'s a pet, and Turn turns', (tester) async {
    HttpOverrides.global = null;
    diskImageCache = false;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final session = Session()..loaded = true;
    late Api api;
    await tester.runAsync(() async {
      api = Api(server: server!);
      final r = await api.post('/api/auth/login', {'username': 'hans', 'password': 'demo password 1'});
      api.token = r['token'] as String;
      session.api = api;
      session.user = User.fromJson(Map<String, dynamic>.from(r['user'] as Map));
      await session.refreshServerVersion();
    });
    expect(session.serverCanFixByHand, isTrue);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: session, child: const SnapshotsApp()));
    await settle(tester);

    await tester.longPress(find.byType(ServerThumb).first);
    await settle(tester, rounds: 2);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await settle(tester, rounds: 6);
    expect(find.text('Turn…'), findsOneWidget);
    expect(find.text("It's a pet…"), findsOneWidget);

    await tester.tap(find.text('Turn…'));
    await settle(tester, rounds: 6);
    expect(find.text('Turn right'), findsOneWidget);
    await tester.tap(find.text('Turn right'));
    await settle(tester, rounds: 6);
    expect(find.textContaining('turned'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 70));
  }, skip: skip != null);

  testWidgets('a pet\'s photo can be taken out of it, and moved to another pet', (tester) async {
    // Needs two pets in the demo library (the first with 3 or more photos): the test seeds none.
    HttpOverrides.global = null;
    diskImageCache = false;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final session = Session()..loaded = true;
    late Api api;
    late int first, second;
    await tester.runAsync(() async {
      api = Api(server: server!);
      final r = await api.post('/api/auth/login', {'username': 'hans', 'password': 'demo password 1'});
      api.token = r['token'] as String;
      session.api = api;
      session.user = User.fromJson(Map<String, dynamic>.from(r['user'] as Map));
      await session.refreshServerVersion();
      final pets = (await api.get('/api/pets') as Map)['pets'] as List;
      first = (pets[0] as Map)['id'] as int;
      second = (pets[1] as Map)['id'] as int;
    });
    Future<int> count(int id) async => ((await api.get('/api/pets/$id')) as Map)['photos'] as int;
    final before = await tester.runAsync(() async => [await count(first), await count(second)]);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: session, child: const SnapshotsApp()));
    await settle(tester);
    await tester.tap(find.text('More'));
    await settle(tester);
    await tester.tap(find.text('Pets').first);
    await settle(tester);
    await tester.tap(find.byType(CoverTile).first);
    await settle(tester);

    Future<void> pickFromMenu(String label) async {
      await tester.longPress(find.byType(ServerThumb).first);
      await settle(tester, rounds: 3);
      await tester.tap(find.byType(PopupMenuButton<String>).last);
      await settle(tester, rounds: 6);
      expect(find.text('Not this pet'), findsOneWidget);
      expect(find.text("It's another pet…"), findsOneWidget);
      expect(find.text("It's a pet…"), findsNothing);      // that is for photos of no pet yet, not on a pet's screen
      await tester.tap(find.text(label));
      await settle(tester, rounds: 6);
    }

    await pickFromMenu('Not this pet');
    final mid = await tester.runAsync(() async => [await count(first), await count(second)]);
    expect(mid![0], before![0] - 1);

    await pickFromMenu("It's another pet…");
    await tester.tap(find.byType(ListTile).first);               // the only other pet
    await settle(tester, rounds: 6);
    final after = await tester.runAsync(() async => [await count(first), await count(second)]);
    expect(after![0], before[0] - 2);
    expect(after[1], before[1] + 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 70));
  }, skip: skip != null);
}
