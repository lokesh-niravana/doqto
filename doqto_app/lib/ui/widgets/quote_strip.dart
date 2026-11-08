import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/enums/app_enums.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../core/utils/rich_text.dart';
import '../../data/models/message.dart';

/// The quoted message inside a reply bubble and above the composer (batch 4):
/// coloured bar, sender name, one-line preview with a type icon. [onTap]
/// jumps to the original; [onClose] (composer only) drops the quote.
class QuoteStrip extends StatelessWidget {
  final ReplyPreview? quote;
  final String senderName;
  final bool isMine;
  final VoidCallback? onTap;
  final VoidCallback? onClose;
  final String? Function(String userId)? nameFor;

  const QuoteStrip({
    super.key,
    required this.quote,
    required this.senderName,
    required this.isMine,
    this.onTap,
    this.onClose,
    this.nameFor,
  });

  IconData? get _icon => switch (quote?.type) {
        MessageType.image => Icons.photo_outlined,
        MessageType.voiceNote => Icons.mic_none_rounded,
        MessageType.file => Icons.description_outlined,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final q = quote;
    final bar = isMine ? AppColors.white : AppColors.medBlue;
    final bg = isMine ? AppColors.white.withValues(alpha: 0.18) : AppColors.gray100;
    final nameColor = isMine ? AppColors.white : AppColors.medBlue;
    final textColor = isMine ? AppColors.white.withValues(alpha: 0.85) : AppColors.textSecondary;
    final preview = q == null
        ? Strings.chatMessageDeleted
        : q.type == MessageType.text
            ? plainText(q.preview ?? '', nameFor: (id) => nameFor?.call(id) ?? 'someone')
            : (q.preview ?? '');
    final deleted = q == null || q.preview == 'Message deleted';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        key: const ValueKey('quote-strip'),
        margin: const EdgeInsets.only(bottom: AppSpacing.xs + 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: AppRadii.rSm,
          border: Border(left: BorderSide(color: bar, width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs + 2, AppSpacing.sm, AppSpacing.xs + 2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    senderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.timestamp.copyWith(color: nameColor, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      if (_icon != null && !deleted) ...[
                        Icon(_icon, size: 14, color: textColor),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                            color: textColor,
                            fontStyle: deleted ? FontStyle.italic : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (onClose != null)
              IconButton(
                key: const ValueKey('quote-close'),
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
                icon: Icon(Icons.close, size: 18, color: textColor),
              ),
          ],
        ),
      ),
    );
  }
}
