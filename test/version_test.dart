import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshots_app/ui/more_screen.dart';

/// The version appears in pubspec.yaml (what the APK is called by Android) and in the app's More
/// screen. One test keeps them equal, so a release can't ship with two different numbers.
void main() {
  test('the version in pubspec.yaml is the one the More screen shows', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    final name = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+\s*$').firstMatch(line)?.group(1);
    expect(name, isNotNull, reason: 'pubspec.yaml needs "version: X.Y.Z+N"');
    expect(appVersion, name);
  });

  test('the tag build is pinned and refuses to publish without the signing key', () {
    final wf = File('.github/workflows/build-apk.yml').readAsStringSync();
    expect(wf, contains(RegExp(r'flutter-version:\s*.?\d+\.\d+\.\d+')));
    expect(wf, contains('refs/tags/v'));
    expect(wf, contains('::error::'));
  });
}
