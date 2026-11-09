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
  Future<void> _crop(int i) async {
    final path = _previews[i].imagePath;
    if (path == null || _cropping) return;
    setState(() => _cropping = true);
    FocusScope.of(context).unfocus();
    try {
      final out = await showImageCrop(context, File(path));
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
                                Positioned(
                                  right: 4,
                                  bottom: 4,
                                  child: Material(
                                    color: AppColors.gray900.withValues(alpha: 0.65),
                                    shape: const CircleBorder(),
                                    child: InkWell(
                                      key: ValueKey('caption-crop-$i'),
                                      customBorder: const CircleBorder(),
                                      onTap: _cropping ? null : () => _crop(i),
                                      child: Tooltip(
                                        message: Strings.captionCrop,
                                        child: const Padding(
                                          padding: EdgeInsets.all(6),
                                          child: Icon(Icons.crop_rounded, size: 18, color: AppColors.white),
                                        ),
                                      ),
                                    ),
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
    );
  }
}
