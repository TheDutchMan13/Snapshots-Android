import 'package:flutter/material.dart';

/// The same teal as Snapshots on the PC.
const accent = Color(0xFF0D5751);
const accentDark = Color(0xFF23766D);
const heart = Color(0xFFD6336C);

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: dark ? accentDark : accent,
    brightness: b,
    surface: dark ? const Color(0xFF14171A) : const Color(0xFFF4F5F7),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 1,
      centerTitle: false,
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

void showMessage(BuildContext context, String text) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text(text)));
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'OK', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

Future<String?> askText(BuildContext context, String title,
    {String initial = '', String label = '', String ok = 'Save'}) async {
  final ctl = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(labelText: label.isEmpty ? null : label),
        onSubmitted: (v) => Navigator.pop(c, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(ok)),
      ],
    ),
  );
  ctl.dispose();
  final t = r?.trim();
  return (t == null || t.isEmpty) ? null : t;
}
