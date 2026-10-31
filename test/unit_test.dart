import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshots_app/api/client.dart';
import 'package:snapshots_app/api/models.dart';
import 'package:snapshots_app/state/feed.dart';

/// Answers requests from a table instead of the network, and remembers what was asked.
class FakeServer implements HttpClientAdapter {
  FakeServer(this.routes);

  final Map<String, (int, Object)> Function(RequestOptions o) routes;
  final asked = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    asked.add(o);
    final table = routes(o);
    final hit = table[o.path] ?? (404, {'detail': 'Not found'});
    return ResponseBody.fromString(jsonEncode(hit.$2), hit.$1, headers: {
      'content-type': ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> asset(int id, String takenAt) => {
      'id': id,
      'filename': 'IMG_$id.jpg',
      'kind': 'photo',
      'size': 1000,
      'taken_at': takenAt,
      'width': 400,
      'height': 300,
      'has_thumb': true,
      'favorite': false,
      'trashed': false,
      'archived': false,
      'live': false,
      'stack_count': 0,
      'rating': 0,
      'v': 'abc$id',
      'place': {'city': 'Tempe', 'state': 'Arizona', 'country': 'United States'},
    };

void main() {
  test('server addresses get http:// and lose trailing slashes', () {
    expect(Api.normalizeServer(' 100.64.1.2:8000/ '), 'http://100.64.1.2:8000');
    expect(Api.normalizeServer('https://pc.tail1.ts.net'), 'https://pc.tail1.ts.net');
    expect(Api.normalizeServer(''), '');
  });

  test('every request says it comes from the app, and carries the token once signed in', () async {
    final fake = FakeServer((_) => {'/api/status': (200, {'ok': true})});
    final api = Api(server: 'pc:8000', token: 'secret')..dio.httpClientAdapter = fake;
    await api.get('/api/status');
    expect(fake.asked.single.headers['X-Snapshots-Request'], '1');
    expect(fake.asked.single.headers['Authorization'], 'Bearer secret');
  });

  test('errors carry the server\'s own sentence, and 401 signs out', () async {
    var signedOut = false;
    final fake = FakeServer((_) => {
          '/api/albums': (401, {'detail': 'Please log in.'}),
          '/api/trash/empty': (403, {'detail': 'Only an administrator can do that.'}),
        });
    final api = Api(server: 'pc', token: 't', onSignedOut: () => signedOut = true)..dio.httpClientAdapter = fake;
    await expectLater(api.post('/api/trash/empty'),
        throwsA(isA<ApiError>().having((e) => e.message, 'm', 'Only an administrator can do that.')));
    expect(signedOut, isFalse);
    await expectLater(api.get('/api/albums'), throwsA(isA<ApiError>().having((e) => e.signedOut, 'signedOut', isTrue)));
    expect(signedOut, isTrue);
  });

  test('query values: false and null are left out, true is "true", empty strings are kept', () async {
    final fake = FakeServer((_) => {'/api/assets': (200, {'items': [], 'next': null})});
    final api = Api(server: 'pc')..dio.httpClientAdapter = fake;
    await api.get('/api/assets', query: {'favorite': false, 'stacks': true, 'state': '', 'album': null});
    expect(fake.asked.single.queryParameters, {'stacks': 'true', 'state': ''});
  });

  test('a feed pages with the cursor and stops on the last page', () async {
    final fake = FakeServer((o) => {
          '/api/assets': o.queryParameters['cursor'] == null
              ? (200, {'items': [asset(3, '2026-10-02T07:00:00'), asset(2, '2026-09-01T07:00:00')], 'next': '2026-09-01T07:00:00|2'})
              : (200, {'items': [asset(1, '2025-01-01T07:00:00')], 'next': null}),
        });
    final feed = Feed(Api(server: 'pc')..dio.httpClientAdapter = fake, const {'archived': 'hide'});
    await feed.loadMore();
    expect(feed.done, isFalse);
    await feed.loadMore();
    expect(feed.done, isTrue);
    expect(feed.items.map((a) => a.id), [3, 2, 1]);
    expect(fake.asked[1].queryParameters['cursor'], '2026-09-01T07:00:00|2');
    expect(fake.asked[1].queryParameters['archived'], 'hide');

    // Jumping to December 2025 starts at the cursor "2026-01|0".
    await feed.jumpTo('2025-12');
    expect(fake.asked.last.queryParameters['cursor'], '2026-01|0');
  });

  test('asset fields', () {
    final a = Asset(asset(7, '2024-07-31T18:22:05'));
    expect(a.monthKey, '2024-07');
    expect(a.thumbPath(), '/api/assets/7/thumb?v=abc7');
    expect(a.place!.label, 'Tempe, Arizona, United States');
    expect(a.aspect, closeTo(1.333, .001));
  });
}
