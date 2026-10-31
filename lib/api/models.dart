// The shapes the Snapshots server sends. Only the fields the app uses are read.

DateTime? _date(dynamic v) => v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;

int? _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : null);

class Place {
  Place({this.city, this.state, this.country});

  factory Place.fromJson(Map<String, dynamic> j) =>
      Place(city: j['city'] as String?, state: j['state'] as String?, country: j['country'] as String?);

  final String? city, state, country;

  String get label => [city, state, country].whereType<String>().where((s) => s.isNotEmpty).join(', ');
}

class Asset {
  Asset(this.j)
      : id = j['id'] as int,
        filename = (j['filename'] as String?) ?? '',
        kind = (j['kind'] as String?) ?? 'photo',
        takenAt = _date(j['taken_at']) ?? DateTime(1970),
        width = _int(j['width']),
        height = _int(j['height']),
        size = _int(j['size']) ?? 0,
        hasThumb = j['has_thumb'] != false,
        favorite = j['favorite'] == true,
        trashed = j['trashed'] == true,
        archived = j['archived'] == true,
        live = j['live'] == true,
        stackCount = _int(j['stack_count']) ?? 0,
        rating = _int(j['rating']) ?? 0,
        v = (j['v'] as String?) ?? '',
        camera = j['camera'] as String?,
        place = j['place'] is Map ? Place.fromJson(Map<String, dynamic>.from(j['place'] as Map)) : null;

  final Map<String, dynamic> j;
  final int id;
  final String filename;
  final String kind;
  final DateTime takenAt;
  final int? width, height;
  final int size;
  final bool hasThumb;
  bool favorite;
  bool trashed;
  bool archived;
  final bool live;
  final int stackCount;
  final int rating;
  final String v;
  final String? camera;
  final Place? place;

  bool get isVideo => kind == 'video';

  String get monthKey => '${takenAt.year.toString().padLeft(4, '0')}-${takenAt.month.toString().padLeft(2, '0')}';

  double get aspect => (width != null && height != null && width! > 0 && height! > 0) ? width! / height! : 1;

  String thumbPath() => '/api/assets/$id/thumb?v=$v';
  String viewPath() => '/api/assets/$id/view?v=$v';
  String motionPath() => '/api/assets/$id/motion?v=$v';
  String originalPath() => '/api/assets/$id/original';
}

/// GET /api/assets/{id}: the asset plus details for the info sheet.
class AssetDetail {
  AssetDetail(Map<String, dynamic> j)
      : asset = Asset(j),
        description = j['description'] as String?,
        text = j['text'] as String?,
        folder = j['folder'] as String?,
        position = j['position'] is List && (j['position'] as List).length == 2
            ? ((j['position'] as List)[0] as num, (j['position'] as List)[1] as num)
            : null,
        people = [
          for (final p in (j['people'] as List? ?? const []))
            (personId: p['person_id'] as int, name: p['name'] as String?, faceId: p['face_id'] as int)
        ],
        albums = [for (final a in (j['albums'] as List? ?? const [])) (id: a['id'] as int, name: a['name'] as String)],
        tags = [for (final t in (j['tags'] as List? ?? const [])) (id: t['id'] as int, name: t['name'] as String)],
        comments = _int(j['comments']) ?? 0;

  final Asset asset;
  final String? description;
  final String? text;
  final String? folder;
  final (num, num)? position;
  final List<({int personId, String? name, int faceId})> people;
  final List<({int id, String name})> albums;
  final List<({int id, String name})> tags;
  final int comments;
}

class Album {
  Album(Map<String, dynamic> j)
      : id = j['id'] as int,
        name = (j['name'] as String?) ?? '',
        count = _int(j['count']) ?? 0,
        cover = _int(j['cover']),
        coverV = (j['cover_v'] as String?) ?? '',
        first = _date(j['first']),
        last = _date(j['last']),
        smart = j['smart'] == true,
        ruleText = j['rule_text'] as String?;

  final int id;
  final String name;
  final int count;
  final int? cover;
  final String coverV;
  final DateTime? first, last;
  final bool smart;
  final String? ruleText;

  String? get coverPath => cover == null ? null : '/api/assets/$cover/thumb?v=$coverV';
}

class Person {
  Person(Map<String, dynamic> j)
      : id = j['id'] as int,
        name = j['name'] as String?,
        hidden = j['hidden'] == true,
        photos = _int(j['photos']) ?? 0,
        faceId = _int(j['face_id']);

  final int id;
  final String? name;
  final bool hidden;
  final int photos;
  final int? faceId;

  bool get named => name != null && name!.trim().isNotEmpty;
  String? get facePath => faceId == null ? null : '/api/faces/$faceId/thumb';
}

/// A tile that opens a grid: a place, tag, memory or event.
class Cover {
  Cover({required this.title, this.subtitle, this.cover, this.coverV = '', required this.query});

  final String title;
  final String? subtitle;
  final int? cover;
  final String coverV;
  final Map<String, dynamic> query;

  String? get coverPath => cover == null ? null : '/api/assets/$cover/thumb?v=$coverV';
}
