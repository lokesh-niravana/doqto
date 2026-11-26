import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/constants/strings.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/models/message.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/app_text_field.dart';
import '../media/image_crop_screen.dart';
import '../media/image_markup_screen.dart';

/// Something the user is about to send, shown above the caption field.
class CaptionPreview {
  final String? imagePath;
  final IconData icon;
  final String label;

  /// Set when the user cropped this photo in the sheet: the path then points
  /// at the cropped JPEG, not the picked file.
  final bool cropped;
  const CaptionPreview({
    this.imagePath,
    this.icon = Icons.insert_drive_file_outlined,
    required this.label,
    this.cropped = false,
  });

  CaptionPreview withImagePath(String path) =>
      CaptionPreview(imagePath: path, icon: icon, label: label, cropped: true);
}

/// What the caption sheet hands back on Send: the trimmed caption and the
/// previews as they stand (a photo the user cropped carries its new path).
class CaptionResult {
  final String caption;
  final List<CaptionPreview> previews;
  const CaptionResult({required this.caption, required this.previews});
}

/// Caption step after picking media (batch 5 A). Returns the caption and
/// the (possibly cropped) previews on Send, null when the user backs out.
Future<CaptionResult?> showCaptionSheet(
  BuildContext context, {
  required List<CaptionPreview> previews,
}) {
  return showModalBottomSheet<CaptionResult>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    // Grows with the keyboard: keep it out from under the status bar / notch.
    useSafeArea: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => CaptionSheet(previews: previews),
  );
}

class CaptionSheet extends StatefulWidget {
  final List<CaptionPreview> previews;
  const CaptionSheet({super.key, required this.previews});

  @override
  State<CaptionSheet> createState() => _CaptionSheetState();
}

class _CaptionSheetState extends State<CaptionSheet> {
  final _controller = TextEditingController();
  late final List<CaptionPreview> _previews = List.of(widget.previews);
  bool _cropping = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(
      CaptionResult(caption: _controller.text.trim(), previews: _previews),
    );
  }

  /// Crop one photo in place; the preview and the file that gets sent both
  /// move to the cropped JPEG. Cancel leaves it as it was.
  Future<void> _crop(int i) => _replaceWith(i, (f) => showImageCrop(context, f));

  /// Markup (draw, highlight, text, block out) — same contract as crop: the
  /// edited JPEG replaces the file that gets sent, the original is not.
  Future<void> _edit(int i) => _replaceWith(i, (f) => showImageMarkup(context, f));

  Future<void> _replaceWith(int i, Future<File?> Function(File) step) async {
    final path = _previews[i].imagePath;
    if (path == null || _cropping) return;
    setState(() => _cropping = true);
    FocusScope.of(context).unfocus();
    try {
      final out = await step(File(path));
      if (out != null && mounted) {
        setState(() => _previews[i] = _previews[i].withImagePath(out.path));
      }
    } finally {
      if (mounted) setState(() => _cropping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final previews = _previews;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        // Scrolls, anchored at the bottom: a four-line caption at a large
        // text size with the keyboard up is taller than what is left of the
        // screen, and the field and Send are what must stay in view.
        child: SingleChildScrollView(
        key: const ValueKey('caption-scroll'),
        reverse: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.sm, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      previews.length == 1 ? previews.first.label : '${previews.length} ${Strings.mediaPhotos.toLowerCase()}',
                      key: const ValueKey('caption-title'),
                      style: AppText.heading,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('caption-close'),
                    tooltip: Strings.a11yClose,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 140,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                itemCount: previews.length,
                separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
                itemBuilder: (_, i) {
                  final p = previews[i];
                  return ClipRRect(
                    borderRadius: AppRadii.rMd,
                    child: Container(
                      width: 120,
                      color: AppColors.gray100,
                      child: p.imagePath != null
                          ? Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.file(File(p.imagePath!), key: ValueKey('caption-image-$i-${p.imagePath}'), fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Icon(p.icon, color: AppColors.gray400, size: 40)),
                                // 30pt discs, 44pt tap areas: the two targets
                                // tile the bottom-right corner edge to edge.
                                Positioned(
                                  right: 44,
                                  bottom: 0,
                                  child: _OverlayButton(
                                    key: ValueKey('caption-edit-$i'),
                                    icon: Icons.edit_rounded,
                                    label: Strings.captionEdit,
                                    inset: const EdgeInsets.only(bottom: 4),
                                    onTap: _cropping ? null : () => _edit(i),
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: _OverlayButton(
                                    key: ValueKey('caption-crop-$i'),
                                    icon: Icons.crop_rounded,
                                    label: Strings.captionCrop,
                                    inset: const EdgeInsets.only(right: 4, bottom: 4),
                                    onTap: _cropping ? null : () => _crop(i),
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(p.icon, color: AppColors.medBlue, size: 40),
                                const SizedBox(height: AppSpacing.xs),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                                  child: Text(p.label, style: AppText.caption, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                                ),
                              ],
                            ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: AppTextField(
                      key: const ValueKey('caption-input'),
                      controller: _controller,
                      semanticLabel: Strings.a11yCaption,
                      hint: Strings.mediaCaptionHint,
                      maxLength: Message.captionMaxLen,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  AppPressable(
                    key: const ValueKey('caption-send'),
                    onTap: _send,
                    haptic: true,
                    semanticLabel: Strings.chatSend,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(color: AppColors.medBlue, shape: BoxShape.circle),
                      child: const Icon(Icons.send_rounded, color: AppColors.white, size: 22),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// Round 30pt button drawn over a preview, inside a 44pt tap area.
class _OverlayButton extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Where the disc sits from the tap area's bottom-right corner.
  final EdgeInsets inset;
  final VoidCallback? onTap;
  const _OverlayButton({
    super.key,
    required this.icon,
    required this.label,
    required this.inset,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        enabled: onTap != null,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Container(
              alignment: Alignment.bottomRight,
              padding: inset,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppColors.gray900.withValues(alpha: 0.65),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 18, color: AppColors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
