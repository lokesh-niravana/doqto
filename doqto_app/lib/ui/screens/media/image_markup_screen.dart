import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../../core/constants/strings.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/utils/image_metadata.dart';
import '../../widgets/scrim_spinner.dart';
import '../../widgets/silent_hint.dart';

/// Markup step before a photo leaves the phone: draw, highlight, add text,
/// and — the one that matters in a clinic — block out or pixelate a region
/// so a name or MRN on a screenshot never gets sent. Pure Dart (Canvas +
/// `image`), no native plugin.
///
/// Every item is stored in *image pixel space*, and the same painter renders
/// the live preview (scaled to fit) and the final full-resolution flatten, so
/// what the user covered is exactly what is gone. Output is a new JPEG
/// (quality 85, metadata stripped); the source file is left untouched.
/// Returns null when the user cancels or made no change.
Future<File?> showImageMarkup(
  BuildContext context,
  File source, {
  @visibleForTesting Directory? outputDir,
}) {
  return Navigator.of(context, rootNavigator: true).push<File?>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ImageMarkupScreen(source: source, outputDir: outputDir),
    ),
  );
}

enum MarkupTool { pen, highlighter, text, block, pixelate }

/// One thing drawn on the image, in image pixel coordinates.
sealed class MarkupItem {
  const MarkupItem();
}

class StrokeItem extends MarkupItem {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool highlighter;
  const StrokeItem({
    required this.points,
    required this.color,
    required this.width,
    required this.highlighter,
  });
}

class RectItem extends MarkupItem {
  final Rect rect;
  final bool pixelate;
  const RectItem({required this.rect, required this.pixelate});
}

class TextItem extends MarkupItem {
  final String text;
  final Offset at; // top-left
  final Color color;
  final double fontSize;

  /// Wrap width: from [at] to the image's right edge (never narrower than a
  /// few characters), so a label never runs off the photo.
  final double maxWidth;
  const TextItem({
    required this.text,
    required this.at,
    required this.color,
    required this.fontSize,
    required this.maxWidth,
  });

  static double wrapWidth(Offset at, double fontSize, double imageWidth) =>
      (imageWidth - at.dx).clamp(fontSize * 4, imageWidth);

  TextItem moved(Offset to, double imageWidth) => TextItem(
        text: text,
        at: to,
        color: color,
        fontSize: fontSize,
        maxWidth: wrapWidth(to, fontSize, imageWidth),
      );
}

class ImageMarkupScreen extends StatefulWidget {
  final File source;
  final Directory? outputDir;

  const ImageMarkupScreen({super.key, required this.source, this.outputDir});

  @override
  State<ImageMarkupScreen> createState() => _ImageMarkupScreenState();
}

const _colorLabelPrefix = 'Colour:';
const _kDiscardMessage = 'Discard your edits to this photo?';
const _kKeepEditing = 'Keep editing';
const _kDiscard = 'Discard';
const _kCanvasLabel = 'Photo being edited';

class _ImageMarkupScreenState extends State<ImageMarkupScreen> {
  static const palette = <(String, Color)>[
    ('white', AppColors.white),
    ('black', Color(0xFF111111)),
    ('red', AppColors.red),
    ('amber', AppColors.amber),
    ('green', AppColors.green),
    ('blue', AppColors.medBlue),
    ('purple', AppColors.purple),
  ];

  ui.Image? _image;

  /// Downscaled copy drawn with nearest-neighbour filtering under pixelate
  /// rects: a real mosaic in the preview, not an approximation.
  ui.Image? _mosaic;
  final List<MarkupItem> _items = [];
  MarkupTool _tool = MarkupTool.pen;
  Color _color = AppColors.red;
  bool _busy = false;
  bool _failed = false;

  // In-progress gesture, image space.
  List<Offset>? _stroke;
  Offset? _rectStart;
  Rect? _rect;
  int? _draggingText;
  Offset? _dragGrab;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    _mosaic?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.source.readAsBytes();
      final image = await decodeImageFromList(bytes);
      final mosaic = await _downscale(image, _mosaicCells(image));
      if (!mounted) {
        image.dispose();
        mosaic.dispose();
        return;
      }
      setState(() {
        _image = image;
        _mosaic = mosaic;
      });
    } catch (_) {
      if (mounted) _fail();
    }
  }

  /// Pixelate cell count across the width: ~40 cells on any image so the
  /// blocks read as blocks and nothing under them is recoverable.
  static int _mosaicCells(ui.Image image) =>
      (image.width / 40).ceil().clamp(4, 400);

  static Future<ui.Image> _downscale(ui.Image image, int cellPx) async {
    final w = (image.width / cellPx).ceil().clamp(1, 1 << 14);
    final h = (image.height / cellPx).ceil().clamp(1, 1 << 14);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.low,
    );
    return rec.endRecording().toImage(w, h);
  }

  void _fail() {
    if (_failed) return;
    _failed = true;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text(Strings.markupFailed)),
    );
    Navigator.of(context).pop(null);
  }

  // --------------------------------------------------------------- sizes --

  double get _imgW => _image!.width.toDouble();
  double get _penWidth => (_imgW / 140).clamp(2, 40);
  double get _highlightWidth => (_imgW / 28).clamp(8, 200);
  double get _fontSize => (_imgW / 16).clamp(14, 300);

  // ------------------------------------------------------------ gestures --

  void _panStart(Offset p) {
    switch (_tool) {
      case MarkupTool.pen:
      case MarkupTool.highlighter:
        setState(() => _stroke = [p]);
      case MarkupTool.block:
      case MarkupTool.pixelate:
        setState(() {
          _rectStart = p;
          _rect = Rect.fromPoints(p, p);
        });
      case MarkupTool.text:
        final i = _textAt(p);
        if (i != null) {
          setState(() {
            _draggingText = i;
            _dragGrab = p - (_items[i] as TextItem).at;
          });
        }
    }
  }

  void _panUpdate(Offset p) {
    if (_stroke != null) {
      setState(() => _stroke!.add(p));
    } else if (_rectStart != null) {
      setState(() => _rect = Rect.fromPoints(_rectStart!, p));
    } else if (_draggingText != null) {
      final t = _items[_draggingText!] as TextItem;
      setState(() => _items[_draggingText!] = t.moved(p - _dragGrab!, _imgW));
    }
  }

  void _panEnd() {
    final stroke = _stroke;
    final rect = _rect;
    setState(() {
      if (stroke != null && stroke.length > 1) {
        final hl = _tool == MarkupTool.highlighter;
        _items.add(StrokeItem(
          points: List.unmodifiable(stroke),
          color: _color,
          width: hl ? _highlightWidth : _penWidth,
          highlighter: hl,
        ));
      }
      if (rect != null && rect.width >= 2 && rect.height >= 2) {
        _items.add(RectItem(
          rect: _clampRect(rect),
          pixelate: _tool == MarkupTool.pixelate,
        ));
      }
      _stroke = null;
      _rectStart = null;
      _rect = null;
      _draggingText = null;
      _dragGrab = null;
    });
  }

  Rect _clampRect(Rect r) {
    final img = _image!;
    return Rect.fromLTRB(
      r.left.clamp(0, img.width.toDouble()),
      r.top.clamp(0, img.height.toDouble()),
      r.right.clamp(0, img.width.toDouble()),
      r.bottom.clamp(0, img.height.toDouble()),
    );
  }

  int? _textAt(Offset p) {
    for (var i = _items.length - 1; i >= 0; i--) {
      final it = _items[i];
      if (it is TextItem && MarkupPainter.textBounds(it).inflate(8).contains(p)) {
        return i;
      }
    }
    return null;
  }

  Future<void> _tap(Offset p) async {
    if (_tool != MarkupTool.text || _busy) return;
    if (_textAt(p) != null) return; // a drag moves it; a tap is a no-op
    final text = await _askText();
    if (text == null || text.trim().isEmpty || !mounted) return;
    setState(() {
      _items.add(TextItem(
        text: text.trim(),
        at: p,
        color: _color,
        fontSize: _fontSize,
        maxWidth: TextItem.wrapWidth(p, _fontSize, _imgW),
      ));
    });
  }

  Future<String?> _askText() =>
      showDialog<String>(context: context, builder: (_) => const _TextEntryDialog());

  void _undo() {
    if (_items.isEmpty || _busy) return;
    setState(() => _items.removeLast());
  }

  // ---------------------------------------------------------------- done --

  Future<void> _done() async {
    final image = _image;
    if (image == null || _busy) return;
    if (_items.isEmpty) {
      Navigator.of(context).pop(null);
      return;
    }
    setState(() => _busy = true);
    try {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      MarkupPainter(
        image: image,
        mosaic: _mosaic,
        items: _items,
        scale: 1,
      ).paintImageSpace(canvas);
      final flat = await rec.endRecording().toImage(image.width, image.height);
      final png = await flat.toByteData(format: ui.ImageByteFormat.png);
      flat.dispose();
      if (png == null) throw StateError('encode');
      final jpeg = await compute(_toJpeg, png.buffer.asUint8List());
      final dir = widget.outputDir ?? await getTemporaryDirectory();
      final file = File(
        '${dir.path}/markup_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(jpeg, flush: true);
      if (mounted) Navigator.of(context).pop(file);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text(Strings.markupFailed)),
        );
      }
    }
  }

  /// Cancel throws the edits away, so it asks first when there are any.
  Future<void> _cancel() async {
    if (_items.isNotEmpty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text(_kDiscardMessage),
          actions: [
            TextButton(
              key: const ValueKey('markup-keep-editing'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(_kKeepEditing),
            ),
            TextButton(
              key: const ValueKey('markup-discard'),
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
              child: const Text(_kDiscard),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    Navigator.of(context).pop(null);
  }

  // --------------------------------------------------------------- build --

  static final _compact = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    minimumSize: const Size(48, 44),
  );

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final text = Theme.of(context).textTheme;
    final body = text.bodyLarge ?? const TextStyle();
    final ready = image != null && !_busy;
    final colorTools = _tool != MarkupTool.block && _tool != MarkupTool.pixelate;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: AppColors.white,
        systemOverlayStyle: null,
        leading: TextButton(
          key: const ValueKey('markup-cancel'),
          style: _compact,
          onPressed: _busy ? null : _cancel,
          // One line always: the slot widens with the text size (below), and
          // past its cap the word scales down instead of wrapping or clipping.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              Strings.markupCancel,
              maxLines: 1,
              softWrap: false,
              style: body.copyWith(color: AppColors.white),
            ),
          ),
        ),
        leadingWidth: (80 * MediaQuery.textScalerOf(context).scale(16) / 16).clamp(80.0, 136.0),
        titleSpacing: 0,
        centerTitle: false,
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            Strings.markupTitle,
            style: (text.titleMedium ?? body).copyWith(color: AppColors.white, fontWeight: FontWeight.w700),
          ),
        ),
        actions: [
          IconButton(
            key: const ValueKey('markup-undo'),
            tooltip: Strings.markupUndo,
            onPressed: ready && _items.isNotEmpty ? _undo : null,
            icon: const Icon(Icons.undo_rounded),
            disabledColor: AppColors.gray400,
          ),
          TextButton(
            key: const ValueKey('markup-done'),
            style: _compact,
            onPressed: ready ? _done : null,
            child: Text(
              Strings.markupDone,
              style: body.copyWith(
                color: ready ? AppColors.medTeal : AppColors.gray400,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: image == null
                  ? const Center(
                      child: CircularProgressIndicator(color: AppColors.white, semanticsLabel: Strings.loading),
                    )
                  : LayoutBuilder(
                      builder: (context, box) {
                        final fit = _fitRect(box.biggest, image);
                        final scale = fit.width / image.width;
                        Offset toImage(Offset local) => Offset(
                              ((local.dx - fit.left) / scale).clamp(0, image.width.toDouble()),
                              ((local.dy - fit.top) / scale).clamp(0, image.height.toDouble()),
                            );
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned.fromRect(
                              rect: fit,
                              // The canvas is a picture to VoiceOver, not a
                              // nameless tappable.
                              child: Semantics(
                                image: true,
                                label: _kCanvasLabel,
                                child: GestureDetector(
                                key: const ValueKey('markup-canvas'),
                                excludeFromSemantics: true,
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (d) => _tap(toImage(d.localPosition + fit.topLeft)),
                                onPanStart: ready
                                    ? (d) => _panStart(toImage(d.localPosition + fit.topLeft))
                                    : null,
                                onPanUpdate: ready
                                    ? (d) => _panUpdate(toImage(d.localPosition + fit.topLeft))
                                    : null,
                                onPanEnd: ready ? (_) => _panEnd() : null,
                                onPanCancel: ready ? _panEnd : null,
                                child: CustomPaint(
                                  painter: MarkupPainter(
                                    image: image,
                                    mosaic: _mosaic,
                                    items: _items,
                                    scale: scale,
                                    pending: _pendingItem(),
                                  ),
                                ),
                              ),
                              ),
                            ),
                            if (_busy)
                              const ColoredBox(
                                color: Color(0x66000000),
                                // On a dark disc: white on the 40% scrim is
                                // under 3:1 over a white photo.
                                child: Center(child: ScrimSpinner()),
                              ),
                          ],
                        );
                      },
                    ),
            ),
            if (colorTools)
              Padding(
                // Seven 44pt cells are 308pt wide, so they fit a 320pt screen;
                // Wrap takes over if a narrower layout ever appears. The dot
                // stays 26pt; only its hit area grew.
                padding: EdgeInsets.zero,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    for (final (name, c) in palette)
                      Semantics(
                        button: true,
                        enabled: ready,
                        selected: _color == c,
                        label: '$_colorLabelPrefix $name',
                        child: InkWell(
                          key: ValueKey('markup-color-$name'),
                          customBorder: const CircleBorder(),
                          onTap: ready ? () => setState(() => _color = c) : null,
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: Center(
                              child: Container(
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _color == c ? AppColors.medTeal : AppColors.gray400,
                                    width: _color == c ? 3 : 1,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              // Five equal slots: at a large text size each label scales down
              // inside its slot instead of pushing the row past the screen.
              child: Row(
                children: [
                  _toolButton(MarkupTool.pen, Icons.edit_rounded, Strings.markupPen, ready),
                  _toolButton(MarkupTool.highlighter, Icons.border_color_rounded, Strings.markupHighlight, ready),
                  _toolButton(MarkupTool.text, Icons.title_rounded, Strings.markupText, ready),
                  _toolButton(MarkupTool.block, Icons.rectangle_rounded, Strings.markupBlock, ready),
                  _toolButton(MarkupTool.pixelate, Icons.blur_on_rounded, Strings.markupPixelate, ready),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  MarkupItem? _pendingItem() {
    final stroke = _stroke;
    if (stroke != null && stroke.length > 1) {
      final hl = _tool == MarkupTool.highlighter;
      return StrokeItem(
        points: stroke,
        color: _color,
        width: hl ? _highlightWidth : _penWidth,
        highlighter: hl,
      );
    }
    final rect = _rect;
    if (rect != null) {
      return RectItem(rect: _clampRect(rect), pixelate: _tool == MarkupTool.pixelate);
    }
    return null;
  }

  Widget _toolButton(MarkupTool tool, IconData icon, String label, bool enabled) {
    final selected = _tool == tool;
    final text = Theme.of(context).textTheme.bodySmall ?? const TextStyle();
    // The filled background is the only visual cue for the active tool, so
    // say it for VoiceOver too.
    return Expanded(
      child: Semantics(
      button: true,
      selected: selected,
      child: InkWell(
      key: ValueKey('markup-tool-${tool.name}'),
      borderRadius: BorderRadius.circular(10),
      onTap: enabled ? () => setState(() => _tool = tool) : null,
      child: Container(
        // Short labels ("Pen") made the button 42pt wide.
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.medBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.white, size: 22),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: text.copyWith(color: AppColors.white, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
      ),
      ),
    );
  }

  static Rect _fitRect(Size box, ui.Image image) {
    final s = (box.width / image.width).clamp(0.0, box.height / image.height);
    final w = image.width * s;
    final h = image.height * s;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }
}

/// Owns its controller and focus node so they outlive the dialog's exit
/// animation (disposing them in `whenComplete` trips "FocusNode was used
/// after being disposed" while the route is still fading out).
class _TextEntryDialog extends StatefulWidget {
  const _TextEntryDialog();

  @override
  State<_TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<_TextEntryDialog> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
        scrollable: true,
      title: const Text(Strings.markupTextTitle),
      // A plain TextField on purpose: AppTextField's token styles pull Google
      // Fonts, and this editor also runs under a bare MaterialApp in tests.
      // Keyboard rule (CLAUDE.md): it dismisses itself on tap-outside.
      content: Semantics(
        label: Strings.a11yMarkupText,
        child: TextField(
          key: const ValueKey('markup-text-input'),
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          maxLength: 120,
          maxLines: 3,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          onTapOutside: (_) => _focus.unfocus(),
          decoration: const InputDecoration(
            hint: SilentHint(Strings.markupTextHint),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('markup-text-cancel'),
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text(Strings.markupCancel),
        ),
        TextButton(
          key: const ValueKey('markup-text-ok'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text(Strings.markupAdd),
        ),
      ],
    );
  }
}

/// Draws the photo and the items. [scale] maps image pixels to the canvas;
/// the flatten pass uses 1 and a canvas the size of the image.
class MarkupPainter extends CustomPainter {
  final ui.Image image;
  final ui.Image? mosaic;
  final List<MarkupItem> items;
  final double scale;
  final MarkupItem? pending;

  const MarkupPainter({
    required this.image,
    required this.mosaic,
    required this.items,
    required this.scale,
    this.pending,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    paintImageSpace(canvas);
    canvas.restore();
  }

  void paintImageSpace(Canvas canvas) {
    final full = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    canvas.drawImageRect(image, full, full, Paint()..filterQuality = FilterQuality.medium);
    for (final it in items) {
      _paintItem(canvas, it);
    }
    final p = pending;
    if (p != null) _paintItem(canvas, p);
  }

  void _paintItem(Canvas canvas, MarkupItem it) {
    switch (it) {
      case StrokeItem():
        final paint = Paint()
          ..color = it.highlighter ? it.color.withValues(alpha: 0.45) : it.color
          ..strokeWidth = it.width
          ..strokeCap = it.highlighter ? StrokeCap.square : StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke
          ..blendMode = it.highlighter ? BlendMode.multiply : BlendMode.srcOver;
        final path = Path()..moveTo(it.points.first.dx, it.points.first.dy);
        for (final p in it.points.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, paint);
      case RectItem():
        if (it.pixelate && mosaic != null) {
          final m = mosaic!;
          final sx = m.width / image.width;
          final sy = m.height / image.height;
          final src = Rect.fromLTRB(
            it.rect.left * sx,
            it.rect.top * sy,
            it.rect.right * sx,
            it.rect.bottom * sy,
          );
          canvas.save();
          canvas.clipRect(it.rect);
          // Snap the source to whole mosaic cells so blocks line up with the
          // grid and no partial-cell averaging leaks detail at the edges.
          final snapped = Rect.fromLTRB(
            src.left.floorToDouble(),
            src.top.floorToDouble(),
            src.right.ceilToDouble(),
            src.bottom.ceilToDouble(),
          );
          final dst = Rect.fromLTRB(
            snapped.left / sx,
            snapped.top / sy,
            snapped.right / sx,
            snapped.bottom / sy,
          );
          canvas.drawImageRect(m, snapped, dst, Paint()..filterQuality = FilterQuality.none);
          canvas.restore();
        } else {
          canvas.drawRect(it.rect, Paint()..color = const Color(0xFF000000));
        }
      case TextItem():
        final tp = _textPainter(it);
        // Soft shadow so the label reads on any background.
        final shadow = _textPainter(it, color: const Color(0x99000000));
        shadow.paint(canvas, it.at + Offset(it.fontSize / 18, it.fontSize / 18));
        tp.paint(canvas, it.at);
    }
  }

  static TextPainter _textPainter(TextItem it, {Color? color}) {
    return TextPainter(
      text: TextSpan(
        text: it.text,
        style: TextStyle(
          color: color ?? it.color,
          fontSize: it.fontSize,
          fontWeight: FontWeight.w700,
          height: 1.15,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: it.maxWidth);
  }

  static Rect textBounds(TextItem it) {
    final tp = _textPainter(it);
    return it.at & tp.size;
  }

  @override
  bool shouldRepaint(MarkupPainter old) =>
      old.image != image ||
      old.items != items ||
      old.items.length != items.length ||
      old.pending != pending ||
      old.scale != scale;
}

/// Isolate entry: PNG from the flatten → JPEG 85, metadata stripped.
Uint8List _toJpeg(Uint8List png) {
  final decoded = img.decodePng(png);
  if (decoded == null) return ImageMetadata.strip(png);
  final jpeg = img.encodeJpg(decoded, quality: 85);
  return ImageMetadata.strip(Uint8List.fromList(jpeg));
}
