import 'dart:io';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../../core/constants/strings.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/utils/image_metadata.dart';

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
          child: Text(
            Strings.cropCancel,
            style: body.copyWith(color: AppColors.white),
          ),
        ),
        leadingWidth: 88,
        title: Text(
          widget.title ?? Strings.cropTitle,
          style: (text.titleMedium ?? body).copyWith(color: AppColors.white, fontWeight: FontWeight.w700),
        ),
        actions: [
          TextButton(
            key: const ValueKey('crop-reset'),
            onPressed: ready ? _reset : null,
            child: Text(
              Strings.cropReset,
              style: body.copyWith(
                color: ready ? AppColors.white : AppColors.gray400,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('crop-done'),
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
                      child: CircularProgressIndicator(color: AppColors.white),
                    )
                  : Stack(
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
                          onCropped: _onCropped,
                          progressIndicator: const Center(
                            child: CircularProgressIndicator(
                              color: AppColors.white,
                            ),
                          ),
                        ),
                        if (_busy)
                          const ColoredBox(
                            color: Color(0x66000000),
                            child: Center(
                              child: CircularProgressIndicator(
                                color: AppColors.white,
                              ),
                            ),
                          ),
                      ],
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
