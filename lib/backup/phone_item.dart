import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

/// One photo or video on the phone, as the backup sees it. The backup only ever works through this,
/// so it can be tested without Android's photo library.
abstract class PhoneItem {
  /// Android's id for it.
  String get id;

  /// When the file was last changed (seconds). A photo edited on the phone is sent again.
  int get modified;

  DateTime get created;

  Future<String> name();

  /// The original file, or null if it can't be read.
  Future<File?> file();
}

/// A photo or video from Android's photo library.
class GalleryItem implements PhoneItem {
  GalleryItem(this.asset);

  final AssetEntity asset;

  @override
  String get id => asset.id;

  @override
  int get modified => asset.modifiedDateSecond ?? 0;

  @override
  DateTime get created => asset.createDateTime;

  @override
  Future<String> name() async {
    var n = asset.title ?? '';
    if (n.isEmpty) {
      try {
        n = await asset.titleAsync;
      } catch (_) {}
    }
    final video = asset.type == AssetType.video;
    if (n.isEmpty) n = '${video ? 'VID' : 'IMG'}_${asset.id}${video ? '.mp4' : '.jpg'}';
    return n;
  }

  @override
  Future<File?> file() async {
    try {
      return await asset.originFile;
    } catch (_) {
      return null;
    }
  }
}
