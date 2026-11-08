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

/// Something the user is about to send, shown above the caption field.
class CaptionPreview {
  final String? imagePath;
  final IconData icon;
  final String label;
  const CaptionPreview({this.imagePath, this.icon = Icons.insert_drive_file_outlined, required this.label});
}

/// Caption step after picking media (batch 5 A). Returns the caption
/// (possibly empty) on Send, null when the user backs out.
Future<String?> showCaptionSheet(
  BuildContext context, {
  required List<CaptionPreview> previews,
}) {
  return showModalBottomSheet<String>(
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final previews = widget.previews;
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
                          ? Image.file(File(p.imagePath!), fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Icon(p.icon, color: AppColors.gray400, size: 40))
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
