import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../data/models/message.dart';
import '../../state/link_preview_state.dart';

/// The site card under a bubble (or above the composer) for the first URL in
/// a message (batch 4). Nothing renders while loading, when previews are off
/// in privacy, or when the server has nothing for the link.
class LinkPreviewCard extends ConsumerWidget {
  final String url;
  final bool isMine;
  final VoidCallback? onTap;
  final VoidCallback? onClose;
  final double? width;

  const LinkPreviewCard({
    super.key,
    required this.url,
    required this.isMine,
    this.onTap,
    this.onClose,
    this.width,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(linkPreviewsEnabledProvider)) return const SizedBox.shrink();
    final preview = ref.watch(linkPreviewProvider(url)).asData?.value;
    if (preview == null) return const SizedBox.shrink();
    return LinkPreviewView(
      preview: preview,
      isMine: isMine,
      onTap: onTap,
      onClose: onClose,
      width: width,
    );
  }
}

/// Pure rendering of a fetched preview (testable without providers).
class LinkPreviewView extends StatelessWidget {
  final LinkPreview preview;
  final bool isMine;
  final VoidCallback? onTap;
  final VoidCallback? onClose;
  final double? width;

  const LinkPreviewView({
    super.key,
    required this.preview,
    required this.isMine,
    this.onTap,
    this.onClose,
    this.width,
  });

  static Uint8List? decodeDataUrl(String? dataUrl) {
    if (dataUrl == null) return null;
    final comma = dataUrl.indexOf(',');
    if (!dataUrl.startsWith('data:') || comma < 0) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  String get _host {
    try {
      return Uri.parse(preview.url).host.replaceFirst('www.', '');
    } catch (_) {
      return preview.url;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = decodeDataUrl(preview.imageDataUrl);
    final bg = isMine
        ? AppColors.white.withValues(alpha: 0.16)
        : AppColors.gray100;
    final title = isMine ? AppColors.white : AppColors.textPrimary;
    final sub = isMine
        ? AppColors.white.withValues(alpha: 0.8)
        : AppColors.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        key: const ValueKey('link-preview'),
        width: width,
        margin: const EdgeInsets.only(top: AppSpacing.xs + 2),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: bg, borderRadius: AppRadii.rSm),
        // The card sits in a bubble / composer column with no height bound;
        // stretching the accent bar and thumbnail needs an intrinsic height.
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                color: isMine
                    ? AppColors.white.withValues(alpha: 0.7)
                    : AppColors.medBlue,
              ),
              if (image != null)
                SizedBox(
                  width: 64,
                  child: Image.memory(
                    image,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (preview.title != null)
                        Text(
                          preview.title!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: title,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (preview.description != null)
                        Text(
                          preview.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(color: sub),
                        ),
                      Text(
                        preview.siteName ?? _host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.timestamp.copyWith(color: sub),
                      ),
                    ],
                  ),
                ),
              ),
              if (onClose != null)
                IconButton(
                  key: const ValueKey('link-preview-close'),
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: Icon(Icons.close, size: 18, color: sub),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
