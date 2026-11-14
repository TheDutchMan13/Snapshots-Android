import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/client.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/session.dart';
import 'media.dart';
import 'theme.dart';

/// What the editor hands back: the photo as it is now, and whether its own file was changed.
class EditResult {
  const EditResult(this.asset, {this.fileChanged = false});
  final Asset asset;
  final bool fileChanged;
}

/// Turn, mirror, straighten and crop a photo, as Snapshots on the PC does. Save keeps only the recipe on the
/// PC: the original file is not changed. An administrator can also choose "Save into the photo's file", which
/// changes the file itself (the PC keeps the old one). Returns an [EditResult], or null if nothing was saved.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.asset});

  final Asset asset;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

/// Crop shapes: width / height of the cropped picture, or null for any shape (0 = the picture's own).
const _ratios = <(String, double?)>[('Free', null), ('Original', 0), ('Square', 1), ('4:3', 4 / 3), ('3:4', 3 / 4), ('16:9', 16 / 9)];

class _EditorScreenState extends State<EditorScreen> {
  int _rotate = 0; // clockwise: 0, 90, 180, 270
  bool _flip = false;
  double _angle = 0; // straighten, degrees, -45..45
  List<double> _crop = [0, 0, 1, 1]; // x, y, w, h of the turned picture, 0..1
  double? _ratio;
  Size? _image; // the unedited picture's size
  ImageProvider? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _saving = false;
  bool _loadedEdits = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final a = widget.asset;
    final api = apiOf(context);
    context.read<Session>().refreshServerVersion(); // (decides whether "Save into the file" is offered)
    _provider = serverImage(api, '/api/assets/${a.id}/view?plain=true&v=${a.v}', cache: false);
    _stream = _provider!.resolve(const ImageConfiguration());
    _listener = ImageStreamListener((info, _) {
      if (mounted) setState(() => _image = Size(info.image.width.toDouble(), info.image.height.toDouble()));
    }, onError: (e, _) {
      if (mounted) setState(() => _error = "Couldn't load the photo.");
    });
    _stream!.addListener(_listener!);
    _loadEdits(api);
  }

  Future<void> _loadEdits(Api api) async {
    try {
      final r = await api.get('/api/assets/${widget.asset.id}');
      final e = r['edits'];
      if (!mounted) return;
      setState(() {
        if (e is Map) {
          _rotate = ((e['rotate'] as num?) ?? 0).toInt() % 360;
          _flip = e['flip'] == true;
          _angle = ((e['straighten'] as num?) ?? 0).toDouble();
          final c = e['crop'];
          if (c is List && c.length == 4) _crop = [for (final v in c) (v as num).toDouble()];
        }
        _loadedEdits = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  void dispose() {
    if (_listener != null) _stream?.removeListener(_listener!);
    super.dispose();
  }

  /// The turned picture's width and height (the frame the crop is measured in).
  Size get _frame {
    final s = _image ?? const Size(4, 3);
    return _rotate % 180 == 0 ? s : Size(s.height, s.width);
  }

  void _turn() => setState(() {
        _rotate = (_rotate + 270) % 360; // a quarter turn to the left, as the button shows
        _crop = [0, 0, 1, 1];
        if (_ratio != null) _fitRatio();
      });

  void _mirror() => setState(() {
        _flip = !_flip;
        _crop = [1 - _crop[0] - _crop[2], _crop[1], _crop[2], _crop[3]];
      });

  double? get _ratioValue => _ratio == 0 ? _frame.width / _frame.height : _ratio;

  /// The biggest centred crop of the chosen shape.
  void _fitRatio() {
    final r = _ratioValue;
    if (r == null) return;
    final f = _frame;
    var w = 1.0, h = (f.width / r) / f.height;
    if (h > 1) {
      h = 1;
      w = (f.height * r) / f.width;
    }
    _crop = [(1 - w) / 2, (1 - h) / 2, w, h];
  }

  bool get _changed =>
      _rotate != 0 || _flip || _angle != 0 || !(_crop[0] == 0 && _crop[1] == 0 && _crop[2] == 1 && _crop[3] == 1);

  Future<void> _save({bool original = false}) async {
    setState(() => _saving = true);
    final whole = _crop[2] >= .999 && _crop[3] >= .999;
    final edits = original || !_changed
        ? null
        : {'rotate': _rotate, 'flip': _flip, 'straighten': double.parse(_angle.toStringAsFixed(2)), 'crop': whole ? null : _crop};
    try {
      final r = await apiOf(context).post('/api/assets/${widget.asset.id}/edits', {'edits': edits});
      if (mounted) Navigator.pop(context, EditResult(Asset(Map<String, dynamic>.from(r as Map))));
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showMessage(context, e.message);
      }
    }
  }

  /// Only an administrator, only a JPEG or PNG photo, and only when the PC's Snapshots can do it.
  bool get _canChangeFile {
    final session = context.watch<Session>();
    final a = widget.asset;
    return session.user?.isAdmin == true &&
        session.serverCanChangeFiles &&
        a.kind == 'photo' &&
        RegExp(r'\.(jpe?g|png)$', caseSensitive: false).hasMatch(a.filename);
  }

  static const _changeFileText =
      "This turns the photo's own file on your PC, not just how Snapshots shows it, so other programs show it that way too. "
      "Snapshots keeps the old file safe (put it back from the photo's details on the PC), saves the picture again at "
      'high quality, and looks for the faces in it again.';

  Future<void> _saveIntoFile() async {
    final ok = await confirm(context, 'Change the original file?', _changeFileText, ok: 'Change the file', danger: true);
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    final whole = _crop[2] >= .999 && _crop[3] >= .999;
    try {
      final api = apiOf(context);
      if (_changed) {
        await api.post('/api/assets/${widget.asset.id}/edits', {
          'edits': {'rotate': _rotate, 'flip': _flip, 'straighten': double.parse(_angle.toStringAsFixed(2)), 'crop': whole ? null : _crop},
        });
      }
      final r = await api.post('/api/assets/${widget.asset.id}/apply-edits', <String, dynamic>{});
      if (mounted) Navigator.pop(context, EditResult(Asset(Map<String, dynamic>.from(r as Map)), fileChanged: true));
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showMessage(context, e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _image != null && _loadedEdits;
    return Theme(
      data: buildTheme(Brightness.dark),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const Text('Edit'),
          actions: [
            if (widget.asset.edited)
              TextButton(onPressed: _saving ? null : () => _save(original: true), child: const Text('Original')),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(onPressed: ready && !_saving ? _save : null, child: Text(_saving ? 'Saving…' : 'Save')),
            ),
            if (_canChangeFile)
              PopupMenuButton<String>(
                enabled: ready && !_saving && (_changed || widget.asset.edited),
                onSelected: (_) => _saveIntoFile(),
                itemBuilder: (_) => const [PopupMenuItem(value: 'file', child: Text("Save into the photo's file…"))],
              ),
          ],
        ),
        body: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)))
            : !ready
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    Expanded(child: Padding(padding: const EdgeInsets.all(20), child: _canvas())),
                    _controls(),
                  ]),
      ),
    );
  }

  Widget _canvas() => LayoutBuilder(builder: (context, c) {
        final f = _frame;
        final k = math.min(c.maxWidth / f.width, c.maxHeight / f.height);
        final w = f.width * k, h = f.height * k;
        final t = _angle * math.pi / 180;
        final s = math.cos(t.abs()) + math.sin(t.abs()) * math.max(f.width / f.height, f.height / f.width);
        // The same steps as the server: turn, mirror, straighten (enlarged to fill), then crop.
        final picture = OverflowBox(
          maxWidth: double.infinity,
          maxHeight: double.infinity,
          child: Transform.rotate(
            angle: t,
            child: Transform.scale(
              scale: s,
              child: Transform.flip(
                flipX: _flip,
                child: RotatedBox(
                  quarterTurns: _rotate ~/ 90,
                  child: SizedBox(
                    width: (_rotate % 180 == 0 ? w : h),
                    height: (_rotate % 180 == 0 ? h : w),
                    child: Image(image: _provider!, fit: BoxFit.fill),
                  ),
                ),
              ),
            ),
          ),
        );
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(child: ClipRect(child: picture)),
              Positioned.fill(child: _CropBox(crop: _crop, size: Size(w, h), ratio: _ratioValue == null ? null : _ratioValue! * h / w, onChanged: (v) => setState(() => _crop = v))),
            ]),
          ),
        );
      });

  Widget _controls() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const SizedBox(width: 12),
            const Icon(Icons.straighten, color: Colors.white70, size: 20),
            Expanded(
              child: Slider(
                min: -45,
                max: 45,
                divisions: 180,
                value: _angle.clamp(-45, 45),
                label: '${_angle.toStringAsFixed(1)}°',
                onChanged: (v) => setState(() => _angle = v),
              ),
            ),
            SizedBox(width: 48, child: Text('${_angle.toStringAsFixed(1)}°', style: const TextStyle(color: Colors.white70))),
          ]),
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final (name, r) in _ratios)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(name),
                    selected: _ratio == r,
                    onSelected: (_) => setState(() {
                      _ratio = r;
                      if (r == null) return;
                      _fitRatio();
                    }),
                  ),
                ),
            ]),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _tool(Icons.rotate_left, 'Turn', _turn),
            _tool(Icons.flip, 'Mirror', _mirror),
            _tool(Icons.crop_free, 'Whole photo', () => setState(() {
                  _crop = [0, 0, 1, 1];
                  _ratio = null;
                })),
            _tool(Icons.restart_alt, 'Start over', () => setState(() {
                  _rotate = 0;
                  _flip = false;
                  _angle = 0;
                  _crop = [0, 0, 1, 1];
                  _ratio = null;
                })),
          ]),
        ]),
      ),
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.white),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ]),
        ),
      );
}

/// The crop rectangle over the picture: drag inside to move it, drag a corner to resize it.
class _CropBox extends StatelessWidget {
  const _CropBox({required this.crop, required this.size, required this.onChanged, this.ratio});

  final List<double> crop;
  final Size size;

  /// Width / height of the crop as a share of the frame (w/h in 0..1 units), or null for any shape.
  final double? ratio;
  final ValueChanged<List<double>> onChanged;

  static const _min = .05;

  void _move(Offset d) {
    final dx = d.dx / size.width, dy = d.dy / size.height;
    final x = (crop[0] + dx).clamp(0.0, 1 - crop[2]), y = (crop[1] + dy).clamp(0.0, 1 - crop[3]);
    onChanged([x, y, crop[2], crop[3]]);
  }

  /// A corner moves; the opposite one stays where it is.
  void _corner(int corner, Offset d) {
    var x0 = crop[0], y0 = crop[1], x1 = crop[0] + crop[2], y1 = crop[1] + crop[3];
    final dx = d.dx / size.width, dy = d.dy / size.height;
    final left = corner == 0 || corner == 2, top = corner == 0 || corner == 1;
    if (left) {
      x0 = (x0 + dx).clamp(0.0, x1 - _min);
    } else {
      x1 = (x1 + dx).clamp(x0 + _min, 1.0);
    }
    if (ratio != null) {
      // Keep the shape: the height follows the width.
      final h = (x1 - x0) / ratio!;
      if (top) {
        y0 = y1 - h;
      } else {
        y1 = y0 + h;
      }
      if (y0 < 0 || y1 > 1) return;
    } else if (top) {
      y0 = (y0 + dy).clamp(0.0, y1 - _min);
    } else {
      y1 = (y1 + dy).clamp(y0 + _min, 1.0);
    }
    onChanged([x0, y0, x1 - x0, y1 - y0]);
  }

  @override
  Widget build(BuildContext context) {
    final r = Rect.fromLTWH(crop[0] * size.width, crop[1] * size.height, crop[2] * size.width, crop[3] * size.height);
    const handle = 36.0;
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _Shade(r)))),
      Positioned.fromRect(
        rect: r,
        child: GestureDetector(
          onPanUpdate: (e) => _move(e.delta),
          child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 1.5))),
        ),
      ),
      for (var i = 0; i < 4; i++)
        Positioned(
          left: (i == 0 || i == 2 ? r.left : r.right) - handle / 2,
          top: (i < 2 ? r.top : r.bottom) - handle / 2,
          width: handle,
          height: handle,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (e) => _corner(i, e.delta),
            child: Center(
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3), boxShadow: const [BoxShadow(blurRadius: 3)]),
              ),
            ),
          ),
        ),
    ]);
  }
}

class _Shade extends CustomPainter {
  _Shade(this.keep);

  final Rect keep;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(keep);
    canvas.drawPath(p, Paint()..color = Colors.black.withValues(alpha: .55));
  }

  @override
  bool shouldRepaint(_Shade old) => old.keep != keep;
}
