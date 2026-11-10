import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshots_app/backup/backup_state.dart';
import 'package:snapshots_app/state/session.dart';

void main() {
  group('stale backup warning', () {
    final now = DateTime(2026, 11, 10, 12);
    int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;

    test('says nothing before the first finished backup, or when it is recent', () {
      expect(BackupStatus.staleWarning(0, now), isNull);
      expect(BackupStatus.staleWarning(ago(const Duration(hours: 5)), now), isNull);
      expect(BackupStatus.staleWarning(ago(const Duration(days: 2, hours: 23)), now), isNull);
    });

    test('says how many days after three', () {
      final w = BackupStatus.staleWarning(ago(const Duration(days: 5, hours: 1)), now);
      expect(w, contains('5 days ago'));
      expect(w, contains('Tailscale'));
    });
  });

  group('server version', () {
    test('compares dotted numbers, not text', () {
      expect(Session.versionAtLeast('0.14.7'), isTrue);
      expect(Session.versionAtLeast('0.14.10'), isTrue); // 10 is more than 7
      expect(Session.versionAtLeast('0.15.0'), isTrue);
      expect(Session.versionAtLeast('1.0'), isTrue);
      expect(Session.versionAtLeast('0.14.6'), isFalse);
      expect(Session.versionAtLeast('0.9.12'), isFalse);
      expect(Session.versionAtLeast('0.14'), isFalse);
    });

    test('an answer that is not a version is not held against the PC', () {
      expect(Session.versionAtLeast(null), isTrue);
      expect(Session.versionAtLeast('1'), isTrue);
      expect(Session.versionAtLeast('dev'), isTrue);
    });

    test('the README names the same oldest version as the app', () {
      final readme = File('README.md').readAsStringSync();
      expect(readme, contains('Snapshots ${Session.minServerVersion} or newer'));
    });
  });
}
