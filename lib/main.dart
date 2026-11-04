import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/session.dart';
import 'ui/actions.dart';
import 'ui/home.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = Session();
  await session.load();
  // Copies left from sharing last time (the share sheet doesn't say when the other app is done).
  AssetActions.clearShared();
  runApp(ChangeNotifierProvider.value(value: session, child: const SnapshotsApp()));
}

final _navigator = GlobalKey<NavigatorState>();

class SnapshotsApp extends StatelessWidget {
  const SnapshotsApp({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    if (session.loaded && !session.signedIn) {
      // Signed out (or the session expired): close any pages left open over the sign-in screen.
      WidgetsBinding.instance.addPostFrameCallback((_) => _navigator.currentState?.popUntil((r) => r.isFirst));
    }
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'Snapshots',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      // A new key per sign-in, so nothing from the last account or PC is left on screen.
      home: !session.loaded
          ? const Scaffold()
          : session.signedIn
              ? Home(key: ValueKey('${session.server}|${session.user!.id}'))
              : const LoginScreen(),
    );
  }
}
