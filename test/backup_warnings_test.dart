import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshots_app/backup/backup_service.dart';
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

    test('saving into the photo\'s file needs a Snapshots that can do it', () {
      expect(Session.versionAtLeast('0.14.7', Session.fileChangeServerVersion), isFalse);
      expect(Session.versionAtLeast('0.15.0', Session.fileChangeServerVersion), isTrue);
      expect(Session.versionAtLeast('0.15.1', Session.fileChangeServerVersion), isTrue);
    });

    test('the README names the same oldest version as the app', () {
      final readme = File('README.md').readAsStringSync();
      expect(readme, contains('Snapshots ${Session.minServerVersion} or newer'));
    });
  });

  group('the hourly run looks only at what changed', () {
    final now = DateTime(2026, 11, 10, 12).millisecondsSinceEpoch;
    int hoursAgo(int h) => now - Duration(hours: h).inMilliseconds;
    DateTime? since({bool background = true, int? listed, int? full, int? at}) => BackupRun.quickListSince(
        background: background, lastListed: listed ?? hoursAgo(1), lastFull: full ?? hoursAgo(5), now: at ?? now);

    test('only the automatic run, only after a full listing in the last day', () {
      expect(since(), isNotNull);
      expect(since(background: false), isNull); // "Back up now" always looks through everything
      expect(since(full: 0), isNull);            // never looked through in full
      expect(since(listed: 0), isNull);
      expect(since(full: hoursAgo(24)), isNull); // a day: time for a full one
      expect(since(full: hoursAgo(23)), isNotNull);
    });

    test('starts before the last listing, so nothing in between is missed', () {
      final t = since(listed: hoursAgo(2))!;
      expect(t.millisecondsSinceEpoch, hoursAgo(2) - BackupRun.listOverlap.inMilliseconds);
    });

    test('a clock that went backwards means a full listing', () {
      expect(since(listed: now + 1000), isNull);
      expect(since(full: now + 1000), isNull);
    });
  });

  test('changing what is backed up makes the next run look through everything', () {
    expect(BackupSettings.listedKey, 'backup.listed');
    expect(BackupSettings.fullListKey, 'backup.listed.full');
  });
}
