import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/services/document_viewer.dart';
import '../../widgets/open_document.dart';
import '../../widgets/primary_button.dart';

/// In-app PDF reading on Android, on the platform's own renderer. iOS uses
/// QuickLook instead. One pan-and-zoom surface over all the pages, built
/// lazily, so a long report costs only the pages near the screen.
class PdfViewerScreen extends ConsumerStatefulWidget {
  final File file;
  final String title;

  const PdfViewerScreen({super.key, required this.file, required this.title});

  @override
  ConsumerState<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends ConsumerState<PdfViewerScreen> {
  static const _gap = 8.0;
  static const _keptPages = 12;
  static const _maxRenderWidth = 2000;

  late final DocumentViewer _viewer = ref.read(documentViewerProvider);
  List<PdfPageSize>? _pages;
  bool _failed = false;
  // Insertion-ordered, so the first key is the least recently used.
  final Map<int, Uint8List> _rendered = {};
  final Set<int> _rendering = {};

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final pages = await _viewer.pdfOpen(widget.file.path);
      if (mounted) setState(() => _pages = pages);
    } catch (_) {
      // Password-protected or corrupt.
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _viewer.pdfClose().catchError((Object _) {});
    super.dispose();
  }

  Future<void> _render(int index, int width) async {
    if (_rendered.containsKey(index) || !_rendering.add(index)) return;
    try {
      final png = await _viewer.pdfPage(index, width);
      if (!mounted) return;
      setState(() {
        _rendered[index] = png;
        while (_rendered.length > _keptPages) {
          _rendered.remove(_rendered.keys.first);
        }
      });
    } catch (_) {
      // Leaves the blank page in place; scrolling back retries it.
    } finally {
      _rendering.remove(index);
    }
  }

  Widget _surface(List<PdfPageSize> pages, BoxConstraints box) {
    final width = box.maxWidth;
    final heights = [for (final s in pages) width * s.height / s.width];
    final tops = <double>[];
    var total = 0.0;
    for (final h in heights) {
      tops.add(total);
      total += h + _gap;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Sharper than the screen so a pinch stays readable.
    final renderWidth = math.min((width * dpr * 1.5).round(), _maxRenderWidth);

    return InteractiveViewer.builder(
      minScale: 1,
      maxScale: 5,
      builder: (context, viewport) {
        final ys = [
          viewport.point0.y,
          viewport.point1.y,
          viewport.point2.y,
          viewport.point3.y,
        ];
        // One screen of margin either side, so scrolling meets ready pages.
        final top = ys.reduce(math.min) - box.maxHeight;
        final bottom = ys.reduce(math.max) + box.maxHeight;
        return SizedBox(
          width: width,
          height: math.max(total, box.maxHeight),
          child: Stack(
            children: [
              for (var i = 0; i < pages.length; i++)
                if (tops[i] + heights[i] >= top && tops[i] <= bottom)
                  Positioned(
                    key: ValueKey(i),
                    top: tops[i],
                    left: 0,
                    width: width,
                    height: heights[i],
                    child: _page(i, renderWidth),
                  ),
            ],
          ),
        );
      },
    );
  }

  Widget _page(int index, int renderWidth) {
    final png = _rendered[index];
    if (png == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _render(index, renderWidth);
      });
      return const ColoredBox(
        color: AppColors.white,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Image.memory(png, fit: BoxFit.fill, gaplessPlayback: true);
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    return Scaffold(
      backgroundColor: AppColors.gray100,
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _failed
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'This PDF can’t be shown here',
                      style: AppText.bodyPrimary,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'It may be password protected.',
                      style: AppText.caption,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      label: 'Open in another app',
                      onPressed: () =>
                          openOutsideDoqto(context, ref, widget.file),
                    ),
                  ],
                ),
              ),
            )
          : pages == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (_, box) => _surface(pages, box)),
    );
  }
}
