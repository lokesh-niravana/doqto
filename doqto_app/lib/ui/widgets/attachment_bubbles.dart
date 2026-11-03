import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../core/di/providers.dart';
import '../../data/models/message.dart';
import '../../data/services/chat_media_cache.dart';
import 'app_pressable.dart';
import 'message_bubble.dart';

/// Timestamp + status ticks row shared by attachment bubbles (mirrors
/// MessageBubble's footer).
class _BubbleFooter extends StatelessWidget {
  final bool isMine;
  final DateTime timestamp;
  final bool read;
  final bool delivered;
  final MessageStatus status;
  const _BubbleFooter({
    required this.isMine,
    required this.timestamp,
    required this.read,
    this.delivered = false,
    this.status = MessageStatus.sent,
  });

  @override
  Widget build(BuildContext context) {
    final timeColor =
        isMine ? AppColors.white.withValues(alpha: 0.55) : AppColors.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          DateFormat.jm().format(timestamp),
          style: AppText.timestamp.copyWith(color: timeColor),
        ),
        if (isMine) ...[
          const SizedBox(width: 3),
          MessageStatusTick(
            status: status,
            read: read,
            delivered: delivered,
            idleColor: AppColors.white.withValues(alpha: 0.55),
          ),
        ],
      ],
    );
  }
}

/// Photo message. Served from [ChatMediaCache] by message id: the first view
/// downloads it (resolving a presigned URL only then), every later view reads
/// the phone. Tap → full-screen viewer, same file.
class ImageBubble extends ConsumerStatefulWidget {
  final String messageId;
  final Future<String> Function() getFileUrl;
  final bool isMine;
  final DateTime timestamp;
  final bool read;
  final bool delivered;

  const ImageBubble({
    super.key,
    required this.messageId,
    required this.getFileUrl,
    required this.isMine,
    required this.timestamp,
    this.read = false,
    this.delivered = false,
  });

  @override
  ConsumerState<ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends ConsumerState<ImageBubble> {
  late final ChatMediaCache _cache = ref.read(chatMediaCacheProvider);
  File? _file;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // Already on the phone this run → paint now, no spinner frame.
    _file = _cache.peek(widget.messageId);
    if (_file == null) _load();
  }

  Future<void> _load() async {
    if (_failed) setState(() => _failed = false);
    try {
      final f = await _cache.image(widget.messageId, widget.getFileUrl);
      if (mounted) setState(() => _file = f);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _openViewer(File file) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                child: Center(child: Image.file(file)),
              ),
            ),
            Positioned(
              top: AppSpacing.lg,
              right: AppSpacing.md,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _broken(double width) => AppPressable(
        // Tap to try again: a miss is usually just a dropped connection.
        onTap: _load,
        child: SizedBox(
          width: width,
          height: 120,
          child: const Icon(Icons.broken_image_outlined, color: Colors.grey),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.sizeOf(context).width * 0.65;
    final file = _file;
    final Widget image;
    if (_failed) {
      image = _broken(maxW - 8);
    } else if (file == null) {
      image = SizedBox(
        width: maxW - 8,
        height: 160,
        child: const Center(child: CircularProgressIndicator()),
      );
    } else {
      image = AppPressable(
        onTap: () => _openViewer(file),
        child: Image.file(
          file,
          width: maxW - 8,
          fit: BoxFit.cover,
          // Decode at bubble size, not camera size: a thread of photos
          // otherwise holds full-resolution bitmaps in memory.
          cacheWidth:
              ((maxW - 8) * MediaQuery.devicePixelRatioOf(context)).round(),
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _broken(maxW - 8),
        ),
      );
    }
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: widget.isMine ? AppColors.medBlue : AppColors.white,
        borderRadius:
            widget.isMine ? AppRadii.bubbleSent : AppRadii.bubbleReceived,
        border: widget.isMine ? null : Border.all(color: AppColors.gray100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(12), child: image),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 3, 4, 2),
            child: _BubbleFooter(
              isMine: widget.isMine,
              timestamp: widget.timestamp,
              read: widget.read,
              delivered: widget.delivered,
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment:
            widget.isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [bubble],
      ),
    );
  }
}

/// Outbox image still uploading (or failed): renders the on-disk file as a
/// real preview — same frame as [ImageBubble] — with a sending/failed tick.
class PendingImageBubble extends StatelessWidget {
  final String path;
  final bool isMine;
  final DateTime timestamp;
  final MessageStatus status;

  const PendingImageBubble({
    super.key,
    required this.path,
    required this.isMine,
    required this.timestamp,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.sizeOf(context).width * 0.65;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isMine ? AppColors.medBlue : AppColors.white,
        borderRadius: isMine ? AppRadii.bubbleSent : AppRadii.bubbleReceived,
        border: isMine ? null : Border.all(color: AppColors.gray100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Opacity(
              opacity: status == MessageStatus.sending ? 0.7 : 1,
              child: Image.file(
                File(path),
                width: maxW - 8,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(
                  height: 120,
                  child:
                      Icon(Icons.broken_image_outlined, color: Colors.grey),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 3, 4, 2),
            child: _BubbleFooter(
              isMine: isMine,
              timestamp: timestamp,
              read: false,
              status: status,
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [bubble],
      ),
    );
  }
}

/// Document message: icon + name + size. Tap → open presigned URL externally.
/// A null [getFileUrl] means the file is still in the local outbox (uploading
/// or failed) — same card, status tick from [status], tap does nothing.
class FileBubble extends StatelessWidget {
  final Future<String> Function()? getFileUrl;
  final String fileName;
  final int? fileSizeBytes;
  final bool isMine;
  final DateTime timestamp;
  final bool read;
  final bool delivered;
  final MessageStatus status;

  const FileBubble({
    super.key,
    required this.getFileUrl,
    required this.fileName,
    this.fileSizeBytes,
    required this.isMine,
    required this.timestamp,
    this.read = false,
    this.delivered = false,
    this.status = MessageStatus.sent,
  });

  String get _sizeLabel {
    final b = fileSizeBytes;
    if (b == null) return '';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _open(BuildContext context) async {
    final resolve = getFileUrl;
    if (resolve == null) return;
    try {
      final url = await resolve();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open the file')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = isMine ? AppColors.white : AppColors.textPrimary;
    final bubble = AppPressable(
      onTap: () => _open(context),
      child: Container(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.72),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
        decoration: BoxDecoration(
          color: isMine ? AppColors.medBlue : AppColors.white,
          borderRadius: isMine ? AppRadii.bubbleSent : AppRadii.bubbleReceived,
          border: isMine ? null : Border.all(color: AppColors.gray100),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.insert_drive_file_outlined, color: fg, size: 30),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        fileName,
                        style: AppText.messageBody.copyWith(color: fg),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_sizeLabel.isNotEmpty)
                        Text(
                          _sizeLabel,
                          style: AppText.timestamp.copyWith(
                            color: isMine
                                ? AppColors.white.withValues(alpha: 0.7)
                                : AppColors.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            _BubbleFooter(
                isMine: isMine,
                timestamp: timestamp,
                read: read,
                delivered: delivered,
                status: status),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [bubble],
      ),
    );
  }
}
