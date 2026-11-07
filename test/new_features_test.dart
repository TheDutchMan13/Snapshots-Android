import 'package:flutter_test/flutter_test.dart';
import 'package:snapshots_app/api/client.dart';
import 'package:snapshots_app/api/models.dart';
import 'package:snapshots_app/state/feed.dart';
import 'package:snapshots_app/ui/details.dart';

import 'unit_test.dart' show FakeServer, asset;

void main() {
  test('coordinates as Google Maps copies them', () {
    expect(parseCoordinates('33.4484, -112.0740'), (lat: 33.4484, lon: -112.074));
    expect(parseCoordinates(' 48.85 2.35 '), (lat: 48.85, lon: 2.35));
    expect(parseCoordinates('91, 10'), isNull);
    expect(parseCoordinates('Phoenix'), isNull);
  });

  test('the Filter menu is sent with every page, and changing it starts again from the top', () async {
    final server = FakeServer((o) => {
          '/api/assets': (200, {
            'items': [asset(1, '2024-05-01T10:00:00')],
            'next': null,
          }),
        });
    final api = Api(server: 'pc:8000')..dio.httpClientAdapter = server;
    final feed = Feed(api, const {'archived': 'hide'});
    await feed.loadMore();
    await feed.setFilter({'rating': 3, 'mono': true});
    final q = server.asked.last.queryParameters;
    expect(q['archived'], 'hide');
    expect(q['rating'], 3);
    expect(q['mono'], 'true');
    expect(feed.items.length, 1);
    await feed.setFilter(const {});
    expect(server.asked.last.queryParameters.containsKey('rating'), isFalse);
  });

  test('a fixed feed (Year in review) loads once and is done', () async {
    var calls = 0;
    final api = Api(server: 'pc:8000');
    final feed = Feed.fixed(api, () async {
      calls++;
      return [Asset(asset(7, '2025-01-01T10:00:00'))];
    });
    await feed.loadMore();
    await feed.loadMore();
    expect(calls, 1);
    expect(feed.done, isTrue);
    expect(feed.items.single.id, 7);
  });

  test('stars, label and flag are read from the server', () {
    final a = Asset({...asset(3, '2025-01-01T10:00:00'), 'rating': 4, 'label': 'green', 'flag': -1, 'edited': true});
    expect((a.rating, a.label, a.flag, a.edited), (4, 'green', -1, true));
    final none = Asset({...asset(4, '2025-01-01T10:00:00'), 'label': ''});
    expect(none.label, isNull);
  });
}

