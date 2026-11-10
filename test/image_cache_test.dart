import 'package:flutter_test/flutter_test.dart';
import 'package:snapshots_app/state/image_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the picture store is big enough for a library and emptying it never fails', () async {
    expect(ImageStore.maxPictures, greaterThanOrEqualTo(10000)); // the library default is 200
    expect(ImageStore.keepDays, greaterThan(30));                // the library default is 30
    ImageStore.enabled = false;                                  // no disk in tests
    await ImageStore.clear();                                    // must not throw
  });
}
