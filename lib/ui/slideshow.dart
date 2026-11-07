import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/feed.dart';
import 'media.dart';

/// The photos of a grid one after another, crossfading, with a choice of speed and shuffle.
/// Videos are left out. The screen stays on while it plays.
class Slideshow extends StatefulWidget {
  const Slideshow({super.key, required this.feed, this.start = 0, this.cache = true});

  final Feed feed;
  final int start;
  final bool cache;

  @override
  State<Slideshow> createState() => _SlideshowState();
}

const _speeds = [3, 5, 8, 12];
const _screen = MethodChannel('snapshots/screen');

class _SlideshowState extends State<Slideshow> {
  late List<Asset> _order;
  int _at = 0;
  int _seconds = 5;
  bool _shuffle = false, _playing = true, _chrome = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _order = _photos();
    final first = widget.start < widget.feed.items.length ? widget.feed.items[widget.start].id : null;
    _at = math.max(0, _order.indexWhere((a) => a.id == first));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _keepOn(true);
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _keepOn(false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  static Future<void> _keepOn(bool on) async {
    try {
      await _screen.invokeMethod<void>('keepOn', on);
    } catch (_) {
      // Not on Android (tests): nothing to do.
    }
  }

  List<Asset> _photos() => [for (final a in widget.feed.items) if (!a.isVideo && a.hasThumb) a];

  void _schedule() {
    _timer?.cancel();
    if (!_playing || _order.isEmpty) return;
    _timer = Timer(Duration(seconds: _seconds), _next);
  }

  Future<void> _next() async {
    if (!mounted || _order.isEmpty) return;
    if (_at + 1 >= _order.length) {
      // Near the end of what's loaded: load more of the grid, then go on (or start again).
      if (!widget.feed.done) {
        await widget.feed.loadMore();
        if (!mounted) return;
        final seen = {for (final a in _order) a.id};
        final more = [for (final a in _photos()) if (!seen.contains(a.id)) a];
        if (_shuffle) more.shuffle();
        _order = [..._order, ...more];
      }
    }
    setState(() => _at = _at + 1 < _order.length ? _at + 1 : 0);
    _precache();
    _schedule();
  }

  void _previous() {
    setState(() => _at = _at > 0 ? _at - 1 : _order.length - 1);
    _schedule();
  }

  void _precache() {
    if (_order.length < 2) return;
    final n = _order[(_at + 1) % _order.length];
    precacheImage(serverImage(apiOf(context), n.viewPath(), cache: widget.cache), context);
  }

  void _setShuffle(bool on) {
    final current = _order.isEmpty ? null : _order[_at];
    setState(() {
      _shuffle = on;
      _order = _photos();
      if (on) _order.shuffle();
      _at = math.max(0, _order.indexWhere((a) => a.id == current?.id));
    });
    _schedule();
  }

  @override
  Widget build(BuildContext context) {
    final api = apiOf(context);
    if (_order.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: const Center(child: Text('No photos here to show.', style: TextStyle(color: Colors.white70))),
      );
    }
    final a = _order[_at];
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _chrome = !_chrome),
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v < -200) _next();
          if (v > 200) _previous();
        },
        child: Stack(fit: StackFit.expand, children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 900),
            child: Image(
              key: ValueKey(a.id),
              image: ResizeImage(serverImage(api, a.viewPath(), cache: widget.cache), width: 2400, height: 2400, policy: ResizeImagePolicy.fit, allowUpscaling: false),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (c, e, s) => Image(image: serverImage(api, a.thumbPath(), cache: widget.cache), fit: BoxFit.contain),
            ),
          ),
          if (_chrome) ...[
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black54,
                padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
                child: Row(children: [
                  IconButton(tooltip: 'Close', color: Colors.white, icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                  Expanded(
                    child: Text(DateFormat.yMMMd().format(a.takenAt), style: const TextStyle(color: Colors.white)),
                  ),
                  Text('${_at + 1} / ${_order.length}${widget.feed.done ? '' : '+'}', style: const TextStyle(color: Colors.white70)),
                  const SizedBox(width: 16),
                ]),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black54,
                padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 4, top: 4),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  IconButton(tooltip: 'Previous', color: Colors.white, icon: const Icon(Icons.skip_previous), onPressed: _previous),
                  IconButton(
                    tooltip: _playing ? 'Pause' : 'Play',
                    color: Colors.white,
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    onPressed: () {
                      setState(() => _playing = !_playing);
                      _schedule();
                    },
                  ),
                  IconButton(tooltip: 'Next', color: Colors.white, icon: const Icon(Icons.skip_next), onPressed: _next),
                  IconButton(
                    tooltip: _shuffle ? 'Shuffle is on' : 'Shuffle',
                    color: _shuffle ? Theme.of(context).colorScheme.primary : Colors.white,
                    icon: const Icon(Icons.shuffle),
                    onPressed: () => _setShuffle(!_shuffle),
                  ),
                  PopupMenuButton<int>(
                    tooltip: 'Speed',
                    initialValue: _seconds,
                    icon: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.timer_outlined, color: Colors.white),
                      const SizedBox(width: 4),
                      Text('${_seconds}s', style: const TextStyle(color: Colors.white)),
                    ]),
                    itemBuilder: (_) => [for (final s in _speeds) PopupMenuItem(value: s, child: Text('$s seconds'))],
                    onSelected: (s) {
                      setState(() => _seconds = s);
                      _schedule();
                    },
                  ),
                ]),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
