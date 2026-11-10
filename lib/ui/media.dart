import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/image_cache.dart';
import '../state/session.dart';

/// Off in tests, which have no disk cache.
bool get diskImageCache => ImageStore.enabled;
set diskImageCache(bool on) => ImageStore.enabled = on;

Api apiOf(BuildContext context, {bool listen = false}) =>
    (listen ? context.watch<Session>() : context.read<Session>()).api!;

/// An image from the server, cached on the phone. [path] includes ?v= when the server gives one,
/// so the cache key changes when the photo does.
ImageProvider serverImage(Api api, String path, {bool cache = true}) {
  if (!cache || !diskImageCache) return NetworkImage(api.url(path), headers: api.authHeaders);
  return CachedNetworkImageProvider(api.url(path), headers: api.authHeaders, cacheKey: '${api.server}$path',
      cacheManager: ImageStore.manager);
}

class ServerThumb extends StatelessWidget {
  const ServerThumb(this.path, {super.key, this.fit = BoxFit.cover, this.icon = Icons.image_outlined, this.cache = true});

  final String? path;
  final BoxFit fit;
  final IconData icon;
  final bool cache;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final placeholder = ColoredBox(
      color: t.colorScheme.surfaceContainerHighest,
      child: Center(child: Icon(icon, color: t.colorScheme.outline)),
    );
    if (path == null) return placeholder;
    final api = apiOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.isFinite ? (c.maxWidth * dpr).round() : null;
      return Image(
        image: w == null ? serverImage(api, path!, cache: cache) : ResizeImage(serverImage(api, path!, cache: cache), width: w, allowUpscaling: false),
        fit: fit,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, sync) => sync || frame != null
            ? child
            : ColoredBox(color: t.colorScheme.surfaceContainerHighest),
        errorBuilder: (_, _, _) => placeholder,
      );
    });
  }
}
