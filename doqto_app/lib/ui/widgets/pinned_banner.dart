import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/enums/app_enums.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../core/utils/rich_text.dart';
import '../../data/models/message.dart';

/// The pinned-message strip at the top of a thread (batch 4). Tap jumps to
/// the message; the trailing button unpins (the server refuses non-admins in
/// groups — the thread shows the error).
class PinnedBanner extends StatelessWidget {
  /// The pinned row when it is loaded; null shows a generic label.
  final Message? message;
  final String? senderName;
  final VoidCallback onTap;
  final VoidCallback? onUnpin;
  final String? Function(String userId)? nameFor;

  const PinnedBanner({
    super.key,
    required this.message,
    required this.senderName,
    required this.onTap,
    this.onUnpin,
    this.nameFor,
  });

  String get _preview {
    final m = message;
    if (m == null) return Strings.chatPinnedMessage;
    return switch (m.type) {
      MessageType.image => 'Photo',
      MessageType.voiceNote => 'Voice note',
      MessageType.file => m.fileName ?? 'File',
      _ => plainText(m.content ?? '', nameFor: (id) => nameFor?.call(id) ?? 'someone'),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('pinned-banner'),
      color: AppColors.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.divider)),
          ),
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
          child: Row(
            children: [
              Container(width: 3, height: 34, color: AppColors.medBlue),
              const SizedBox(width: AppSpacing.sm),
              const Icon(Icons.push_pin_rounded, size: 18, color: AppColors.medBlue),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      senderName == null
                          ? Strings.chatPinnedMessage
                          : '${Strings.chatPinnedMessage} · $senderName',
                      style: AppText.timestamp.copyWith(
                        color: AppColors.medBlue,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _preview,
                      key: const ValueKey('pinned-banner-text'),
                      style: AppText.caption.copyWith(color: AppColors.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (onUnpin != null)
                IconButton(
                  key: const ValueKey('pinned-banner-unpin'),
                  tooltip: Strings.chatUnpinMessage,
                  onPressed: onUnpin,
                  icon: Icon(Icons.close, size: 20, color: AppColors.textMuted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
