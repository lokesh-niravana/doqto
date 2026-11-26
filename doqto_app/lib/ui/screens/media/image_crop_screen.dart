import 'dart:io';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../../core/constants/strings.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/utils/crop_geometry.dart';
import '../../../core/utils/image_metadata.dart';
import '../../widgets/scrim_spinner.dart';

/// Crop step before a picture leaves the phone: profile / group photos
/// (circle mask, square output) and chat photos (free aspect with quick
/// presets). Pure Dart (`crop_your_image` + `image`), no native plugin.
///
/// Returns the cropped JPEG (quality 85, metadata stripped) as a temp file,
/// or null when the user cancels. [outputDir] overrides the temp folder
/// (tests have no path_provider).
Future<File?> showImageCrop(
  BuildContext context,
  File source, {
  bool circle = false,
  double? aspectRatio,
  String? title,
  @visibleForTesting Directory? outputDir,
}) {
  return Navigator.of(context, rootNavigator: true).push<File?>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ImageCropScreen(
        source: source,
        circle: circle,
        aspectRatio: aspectRatio,
        title: title,
        outputDir: outputDir,
      ),
    ),
  );
}

class ImageCropScreen extends StatefulWidget {
  final File source;
  final bool circle;
  final double? aspectRatio;
  final String? title;
  final Directory? outputDir;

  const ImageCropScreen({
    super.key,
    required this.source,
    this.circle = false,
    this.aspectRatio,
    this.title,
    this.outputDir,
  });

  @override
  State<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends State<ImageCropScreen> {
  final _controller = CropController();
  Uint8List? _bytes;
  CropStatus _status = CropStatus.nothing;
  bool _busy = false;
  double? _aspect;

  // Where the crop rectangle and the picture are inside the canvas, as the
  // crop widget last reported them. The 44pt corner targets are laid out
  // from these (the package's own handles are 32pt and cannot be enlarged).
  Rect? _cropRect;
  Rect? _imageRect;

  // A corner drag in progress: the rect it started from and how far the
  // finger has travelled since.
  Rect? _dragFrom;
  Offset _dragDelta = Offset.zero;

  static const _presets = <(String, double?)>[
    (Strings.cropAspectFree, null),
    ('1:1', 1),
    ('4:3', 4 / 3),
    ('16:9', 16 / 9),
  ];

  @override
  void initState() {
    super.initState();
    _aspect = widget.circle ? 1 : widget.aspectRatio;
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await widget.source.readAsBytes();
      if (mounted) setState(() => _bytes = b);
    } catch (_) {
      if (mounted) _fail();
    }
  }

  void _fail() {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text(Strings.cropFailed)),
    );
    Navigator.of(context).pop(null);
  }

  /// Records what the crop widget reports. It calls back from gestures and
  /// from its own async set-up, never during a build — but if that ever
  /// changes, wait for the frame instead of calling setState inside one.
  void _track(VoidCallback update) {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(update);
      });
    } else {
      setState(update);
    }
  }

  void _dragCorner(CropCorner corner, Offset delta, Size viewport) {
    final from = _dragFrom;
    final image = _imageRect;
    if (from == null || image == null) return;
    _dragDelta += delta;
    // Only the part of the picture that is on screen can be cropped to.
    final bounds = image.intersect(Offset.zero & viewport);
    _controller.cropRect = resizeCropRect(
      rect: from,
      corner: corner,
      delta: _dragDelta,
      bounds: bounds,
      // The circle mask is a fixed 1:1 (set in initState).
      aspectRatio: _aspect,
    );
  }

  /// Four 44x44pt drag targets over the crop corners. They sit above the
  /// crop widget's own 32pt handles (which stay as the visible dots) and
  /// resize the rectangle through the controller.
  List<Widget> _cornerTargets(Size viewport) {
    final rect = _cropRect;
    if (rect == null || _imageRect == null) return const [];
    return [
      for (final corner in CropCorner.values)
        Positioned.fromRect(
          rect: cropHandleTarget(corner.of(rect), viewport),
          child: GestureDetector(
            key: ValueKey('crop-handle-${corner.name}'),
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onPanStart: (_) {
              _dragFrom = _cropRect;
              _dragDelta = Offset.zero;
            },
            onPanUpdate: (d) => _dragCorner(corner, d.delta, viewport),
            onPanEnd: (_) => _dragFrom = null,
            onPanCancel: () => _dragFrom = null,
          ),
        ),
    ];
  }

  void _reset() {
    final b = _bytes;
    if (b == null) return;
    // Re-setting the image resets the crop rect to the default.
    _controller.image = b;
  }

  void _setAspect(double? a) {
    setState(() => _aspect = a);
    _controller.aspectRatio = a;
  }

  void _done() {
    if (_busy || _status != CropStatus.ready) return;
    setState(() => _busy = true);
    // Square output even for the circle UI: the avatar widgets clip to a
    // circle themselves and a square JPEG has no transparency to lose.
    _controller.crop();
  }

  Future<void> _onCropped(CropResult result) async {
    switch (result) {
      case CropFailure():
        if (mounted) {
          setState(() => _busy = false);
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text(Strings.cropFailed)),
          );
        }
      case CropSuccess(:final croppedImage):
        try {
          final jpeg = await compute(_toJpeg, croppedImage);
          final dir = widget.outputDir ?? await getTemporaryDirectory();
          final file = File(
            '${dir.path}/crop_${DateTime.now().microsecondsSinceEpoch}.jpg',
          );
          await file.writeAsBytes(jpeg, flush: true);
          if (mounted) Navigator.of(context).pop(file);
        } catch (_) {
          if (mounted) {
            setState(() => _busy = false);
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(content: Text(Strings.cropFailed)),
            );
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final ready = _status == CropStatus.ready && !_busy;
    // Theme text styles (DM Sans via AppTheme) rather than the static token
    // styles: this editor also runs in tests with a bare MaterialApp.
    final text = Theme.of(context).textTheme;
    final body = text.bodyLarge ?? const TextStyle();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: AppColors.white,
        systemOverlayStyle: null,
        leading: TextButton(
          key: const ValueKey('crop-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(null),
          // One line always: the slot widens with the text size (below), and
          // past its cap the word scales down instead of wrapping or clipping.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              Strings.cropCancel,
              maxLines: 1,
              softWrap: false,
              style: body.copyWith(color: AppColors.white),
            ),
          ),
        ),
        leadingWidth: (88 * MediaQuery.textScalerOf(context).scale(16) / 16).clamp(88.0, 144.0),
        // Cancel grows to 144pt at large text; the title gives way by
        // scaling down, and Reset is an icon, so nothing is squeezed out.
        titleSpacing: 0,
        centerTitle: false,
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            widget.title ?? Strings.cropTitle,
            style: (text.titleMedium ?? body).copyWith(color: AppColors.white, fontWeight: FontWeight.w700),
          ),
        ),
        actions: [
          IconButton(
            key: const ValueKey('crop-reset'),
            tooltip: Strings.cropReset,
            onPressed: ready ? _reset : null,
            color: AppColors.white,
            disabledColor: AppColors.gray400,
            icon: const Icon(Icons.restart_alt),
          ),
          TextButton(
            key: const ValueKey('crop-done'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(48, 44),
            ),
            onPressed: ready ? _done : null,
            child: Text(
              Strings.cropDone,
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
              child: bytes == null
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.white,
                        semanticsLabel: Strings.loading,
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, box) => Stack(
                      fit: StackFit.expand,
                      children: [
                        Crop(
                          key: const ValueKey('crop-canvas'),
                          image: bytes,
                          controller: _controller,
                          aspectRatio: _aspect,
                          withCircleUi: widget.circle,
                          interactive: true,
                          baseColor: Colors.black,
                          maskColor: Colors.black.withValues(alpha: 0.6),
                          radius: widget.circle ? 0 : 8,
                          onStatusChanged: (s) {
                            if (mounted) setState(() => _status = s);
                          },
                          onMoved: (viewportRect, _) =>
                              _track(() => _cropRect = viewportRect),
                          onImageMoved: (imageRect) =>
                              _track(() => _imageRect = imageRect),
                          onCropped: _onCropped,
                          progressIndicator: const Center(child: ScrimSpinner()),
                        ),
                        if (ready) ..._cornerTargets(box.biggest),
                        if (_busy)
                          const ColoredBox(
                            color: Color(0x66000000),
                            // On a dark disc: white on the 40% scrim is under
                            // 3:1 over a white photo.
                            child: Center(child: ScrimSpinner()),
                          ),
                      ],
                    ),
                    ),
            ),
            if (!widget.circle)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                child: Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    for (final p in _presets)
                      ChoiceChip(
                        key: ValueKey('crop-aspect-${p.$1}'),
                        label: Text(p.$1),
                        selected: _aspect == p.$2,
                        onSelected: ready ? (_) => _setAspect(p.$2) : null,
                        selectedColor: AppColors.medBlue,
                        backgroundColor: AppColors.gray800,
                        labelStyle: (text.bodySmall ?? body).copyWith(
                          color: AppColors.white,
                        ),
                        side: BorderSide.none,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Isolate entry: re-encode the crop as JPEG 85 and strip metadata.
Uint8List _toJpeg(Uint8List cropped) {
  final decoded = img.decodeImage(cropped);
  if (decoded == null) return ImageMetadata.strip(cropped);
  final jpeg = img.encodeJpg(decoded, quality: 85);
  return ImageMetadata.strip(Uint8List.fromList(jpeg));
}
