import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/chat_theme.dart';
import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../core/di/providers.dart';
import '../../data/models/message.dart';
import '../../data/services/chat_media_cache.dart';
import 'app_pressable.dart';
import 'message_bubble.dart';
import 'message_text.dart';
import 'open_document.dart';

/// Timestamp + status ticks row shared by attachment bubbles (mirrors
/// MessageBubble's footer).
class BubbleFooter extends StatelessWidget {
  final bool isMine;
  final DateTime timestamp;
  final bool read;
  final bool delivered;
  final MessageStatus status;
  final bool onMedia;
  const BubbleFooter({
    super.key,
    required this.isMine,
    required this.timestamp,
    required this.read,
    this.delivered = false,
    this.status = MessageStatus.sent,
    this.onMedia = false,
  });

  @override
  Widget build(BuildContext context) {
    final sentFg = ChatThemeScope.of(context).sentFg;
    final timeColor = onMedia
        ? AppColors.white
        : isMine
            ? sentFg.withValues(alpha: 0.55)
            : AppColors.textMuted;
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
            idleColor: onMedia ? AppColors.white : sentFg.withValues(alpha: 0.55),
          ),
        ],
      ],
    );
  }
}

/// Caption under a photo / video / file / voice note (batch 5 A).
class MediaCaption extends StatelessWidget {
  final String text;
  final bool isMine;
  final EdgeInsets padding;
  const MediaCaption({
    super.key,
    required this.text,
    required this.isMine,
    this.padding = const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs, AppSpacing.sm, 0),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Align(
        alignment: Alignment.centerLeft,
        child: MessageText(
          key: const ValueKey('media-caption'),
          text: text,
          style: messageBodyStyle(isMine: isMine),
          isMine: isMine,
        ),
      ),
    );
  }
}

/// Thin overlay used while an outbox upload is in flight: a ring with the
/// fraction, or an indeterminate ring until the first part lands.
class UploadRing extends StatelessWidget {
  final double? progress;
  const UploadRing({super.key, this.progress});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.gray900.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      padding: const EdgeInsets.all(8),
      child: CircularProgressIndicator(
        key: const ValueKey('upload-ring'),
        value: progress == null || progress! <= 0 ? null : progress!.clamp(0.0, 1.0),
        strokeWidth: 3,
        valueColor: const AlwaysStoppedAnimation(AppColors.white),
        backgroundColor: AppColors.white.withValues(alpha: 0.3),
      ),
    );
  }
}

/// "Tap to download" tile for media the auto-download rules kept off the
/// network (batch 5 G).
class DownloadPlaceholder extends StatelessWidget {
  final double width;
  final double height;
  final String label;
  final VoidCallback onTap;
  final bool loading;
  const DownloadPlaceholder({
    super.key,
    required this.width,
    required this.height,
    required this.label,
    required this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return AppPressable(
      key: const ValueKey('media-download'),
      onTap: loading ? null : onTap,
      child: Container(
        width: width,
        height: height,
        color: AppColors.gray100,
        child: Center(
          child: loading
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.gray900.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.download_rounded, color: AppColors.white),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(label, style: AppText.timestamp.copyWith(color: AppColors.textMuted)),
                  ],
                ),
        ),
      ),
    );
  }
}

Widget _frame(BuildContext context, {required bool isMine, required Widget bubble}) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
    child: Row(
      mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [bubble],
    ),
  );
}

/// Bubble chrome from the thread's chat theme (batch 6), like MessageBubble —
/// a hard-coded white received bubble was unreadable under the dark palette.
BoxDecoration _mediaDecoration(BuildContext context, bool isMine) {
  final chatTheme = ChatThemeScope.of(context);
  final border = chatTheme.receivedBorder;
  return BoxDecoration(
    color: isMine ? chatTheme.sentBg : chatTheme.receivedBg,
    borderRadius: isMine ? AppRadii.bubbleSent : AppRadii.bubbleReceived,
    border: isMine || border == null ? null : Border.all(color: border),
  );
}

String fileSizeLabel(int? b) {
  if (b == null) return '';
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Photo message. Served from [ChatMediaCache] by message id: the first view
/// downloads it (resolving a presigned URL only then), every later view reads
/// the phone. Tap → [onOpen] (the thread's viewer) or a plain full-screen view.
class ImageBubble extends ConsumerStatefulWidget {
  final String messageId;
  final String? conversationId;
  final Future<String> Function() getFileUrl;
  final bool isMine;
  final DateTime timestamp;
  final bool read;
  final bool delivered;
  final String? caption;

  /// False → show a download tile until tapped (auto-download rule).
  final bool autoDownload;
  final void Function(File file)? onOpen;

  /// Aspect ratio hint so the placeholder has the final height.
  final int? width;
  final int? height;

  const ImageBubble({
    super.key,
    required this.messageId,
    required this.getFileUrl,
    required this.isMine,
    required this.timestamp,
    this.conversationId,
    this.read = false,
    this.delivered = false,
    this.caption,
    this.autoDownload = true,
    this.onOpen,
    this.width,
    this.height,
  });

  @override
  ConsumerState<ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends ConsumerState<ImageBubble> {
  late final ChatMediaCache _cache = ref.read(chatMediaCacheProvider);
  File? _file;
  bool _failed = false;
  bool _loading = false;
  bool _waitingForTap = false;

  @override
  void initState() {
    super.initState();
    // Already on the phone this run → paint now, no spinner frame.
    _file = _cache.peek(widget.messageId);
    if (_file == null) {
      if (widget.autoDownload) {
        _load();
      } else {
        _waitingForTap = true;
        _checkDisk();
      }
    }
  }

  Future<void> _checkDisk() async {
    final f = await _cache.cached(widget.messageId);
    if (f != null && mounted) {
      setState(() {
        _file = f;
        _waitingForTap = false;
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _failed = false;
      _loading = true;
      _waitingForTap = false;
    });
    try {
      final f = await _cache.image(widget.messageId, widget.getFileUrl, conversationId: widget.conversationId);
      if (mounted) setState(() => _file = f);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openViewer(File file) {
    if (widget.onOpen != null) {
      widget.onOpen!(file);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: AppColors.gray900,
        child: Stack(
          children: [
            Positioned.fill(child: InteractiveViewer(child: Center(child: Image.file(file)))),
            Positioned(
              top: AppSpacing.lg,
              right: AppSpacing.md,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.close, color: AppColors.white),
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
          child: Icon(Icons.broken_image_outlined, color: AppColors.gray400),
        ),
      );

  double _placeholderHeight(double w) {
    final iw = widget.width, ih = widget.height;
    if (iw == null || ih == null || iw <= 0) return 160;
    return (w * ih / iw).clamp(80.0, 320.0);
  }

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.sizeOf(context).width * 0.65;
    final w = maxW - 8;
    final file = _file;
    final Widget image;
    if (_failed) {
      image = _broken(w);
    } else if (file == null && _waitingForTap) {
      image = DownloadPlaceholder(
        width: w,
        height: _placeholderHeight(w),
        label: Strings.mediaTapToDownload,
        onTap: _load,
        loading: _loading,
      );
    } else if (file == null) {
      image = SizedBox(width: w, height: _placeholderHeight(w), child: const Center(child: CircularProgressIndicator()));
    } else {
      image = AppPressable(
        key: ValueKey('image-open-${widget.messageId}'),
        onTap: () => _openViewer(file),
        child: Image.file(
          file,
          width: w,
          fit: BoxFit.cover,
          // Decode at bubble size, not camera size: a thread of photos
          // otherwise holds full-resolution bitmaps in memory.
          cacheWidth: (w * MediaQuery.devicePixelRatioOf(context)).round(),
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _broken(w),
        ),
      );
    }
    final hasCaption = widget.caption != null && widget.caption!.isNotEmpty;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      padding: const EdgeInsets.all(4),
      decoration: _mediaDecoration(context, widget.isMine),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(borderRadius: AppRadii.rMd, child: image),
          if (hasCaption) MediaCaption(text: widget.caption!, isMine: widget.isMine),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 3, 4, 2),
            child: BubbleFooter(
              isMine: widget.isMine,
              timestamp: widget.timestamp,
              read: widget.read,
              delivered: widget.delivered,
            ),
          ),
        ],
      ),
    );
    return _frame(context, isMine: widget.isMine, bubble: bubble);
  }
}

/// Outbox image still uploading (or failed): renders the on-disk file as a
/// real preview — same frame as [ImageBubble] — with a sending/failed tick
/// and the upload ring.
class PendingImageBubble extends StatelessWidget {
  final String path;
  final bool isMine;
  final DateTime timestamp;
  final MessageStatus status;
  final String? caption;
  final double? progress;

  const PendingImageBubble({
    super.key,
    required this.path,
    required this.isMine,
    required this.timestamp,
    required this.status,
    this.caption,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.sizeOf(context).width * 0.65;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      padding: const EdgeInsets.all(4),
      decoration: _mediaDecoration(context, isMine),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: AppRadii.rMd,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: status == MessageStatus.sending ? 0.7 : 1,
                  child: Image.file(
                    File(path),
                    width: maxW - 8,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => SizedBox(
                      height: 120,
                      child: Icon(Icons.broken_image_outlined, color: AppColors.gray400),
                    ),
                  ),
                ),
                if (status == MessageStatus.sending) UploadRing(progress: progress),
              ],
            ),
          ),
          if (caption != null && caption!.isNotEmpty) MediaCaption(text: caption!, isMine: isMine),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 3, 4, 2),
            child: BubbleFooter(isMine: isMine, timestamp: timestamp, read: false, status: status),
          ),
        ],
      ),
    );
    return _frame(context, isMine: isMine, bubble: bubble);
  }
}

/// Video message (batch 5 C): poster + duration + play. The poster comes
/// from the cache (`#thumb`), the clip only when played — or ahead of time
/// when the auto-download rule allows.
class VideoBubble extends ConsumerStatefulWidget {
  final String messageId;
  final String? conversationId;
  final Future<String> Function() getFileUrl;
  final Future<String> Function() getThumbUrl;
  final int durationSec;
  final bool isMine;
  final DateTime timestamp;
  final bool read;
  final bool delivered;
  final String? caption;
  final int? width;
  final int? height;
  final bool autoDownload;
  final VoidCallback onOpen;

  const VideoBubble({
    super.key,
    required this.messageId,
    required this.getFileUrl,
    required this.getThumbUrl,
    required this.durationSec,
    required this.isMine,
    required this.timestamp,
    required this.onOpen,
    this.conversationId,
    this.read = false,
    this.delivered = false,
    this.caption,
    this.width,
    this.height,
    this.autoDownload = false,
  });

  static String formatDuration(int sec) => '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';

  @override
  ConsumerState<VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends ConsumerState<VideoBubble> {
  late final ChatMediaCache _cache = ref.read(chatMediaCacheProvider);
  File? _poster;
  bool _posterFailed = false;

  @override
  void initState() {
    super.initState();
    _poster = _cache.peek(ChatMediaCache.thumbId(widget.messageId));
    if (_poster == null) _loadPoster();
    if (widget.autoDownload) {
      // Fire and forget: the player reads the cache when opened.
      _cache.media(widget.messageId, widget.getFileUrl, conversationId: widget.conversationId).ignore();
    }
  }

  Future<void> _loadPoster() async {
    try {
      final f = await _cache.thumbnail(widget.messageId, widget.getThumbUrl, conversationId: widget.conversationId);
      if (mounted) setState(() => _poster = f);
    } catch (_) {
      if (mounted) setState(() => _posterFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.sizeOf(context).width * 0.65;
    final w = maxW - 8;
    final iw = widget.width, ih = widget.height;
    final h = (iw != null && ih != null && iw > 0) ? (w * ih / iw).clamp(100.0, 320.0) : w * 9 / 16;
    final poster = _poster;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      padding: const EdgeInsets.all(4),
      decoration: _mediaDecoration(context, widget.isMine),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: AppRadii.rMd,
            child: AppPressable(
              key: ValueKey('video-open-${widget.messageId}'),
              onTap: widget.onOpen,
              child: SizedBox(
                width: w,
                height: h,
                child: Stack(
                  fit: StackFit.expand,
                  alignment: Alignment.center,
                  children: [
                    if (poster != null)
                      Image.file(poster, fit: BoxFit.cover, gaplessPlayback: true,
                          cacheWidth: (w * MediaQuery.devicePixelRatioOf(context)).round())
                    else
                      Container(
                        color: AppColors.gray800,
                        child: _posterFailed
                            ? null
                            : const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.white))),
                      ),
                    Center(
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppColors.gray900.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow_rounded, color: AppColors.white, size: 32),
                      ),
                    ),
                    Positioned(
                      left: AppSpacing.sm,
                      bottom: AppSpacing.sm,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.gray900.withValues(alpha: 0.55),
                          borderRadius: AppRadii.rSm,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.videocam_rounded, size: 12, color: AppColors.white),
                            const SizedBox(width: 3),
                            Text(
                              VideoBubble.formatDuration(widget.durationSec),
                              key: ValueKey('video-duration-${widget.messageId}'),
                              style: AppText.timestamp.copyWith(color: AppColors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.caption != null && widget.caption!.isNotEmpty) MediaCaption(text: widget.caption!, isMine: widget.isMine),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 3, 4, 2),
            child: BubbleFooter(isMine: widget.isMine, timestamp: widget.timestamp, read: widget.read, delivered: widget.delivered),
          ),
        ],
      ),
    );
    return _frame(context, isMine: widget.isMine, bubble: bubble);
  }
}

/// Outbox video uploading: local poster + ring with the upload fraction.
class PendingVideoBubble extends StatelessWidget {
  final String? posterPath;
  final int durationSec;
  final bool isMine;
  final DateTime timestamp;
  final MessageStatus status;
  final String? caption;
  final double? progress;
  final int? width;
  final int? height;

  const PendingVideoBubble({
    super.key,
    required this.posterPath,
    required this.durationSec,
    required this.isMine,
    required this.timestamp,
    required this.status,
    this.caption,
    this.progress,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.sizeOf(context).width * 0.65;
    final w = maxW - 8;
    final iw = width, ih = height;
    final h = (iw != null && ih != null && iw > 0) ? (w * ih / iw).clamp(100.0, 320.0) : w * 9 / 16;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      padding: const EdgeInsets.all(4),
      decoration: _mediaDecoration(context, isMine),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: AppRadii.rMd,
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                fit: StackFit.expand,
                alignment: Alignment.center,
                children: [
                  if (posterPath != null)
                    Opacity(
                      opacity: status == MessageStatus.sending ? 0.7 : 1,
                      child: Image.file(File(posterPath!), fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(color: AppColors.gray800)),
                    )
                  else
                    Container(color: AppColors.gray800),
                  if (status == MessageStatus.sending)
                    Center(child: UploadRing(progress: progress))
                  else if (status == MessageStatus.failed)
                    const Center(child: Icon(Icons.error_outline_rounded, color: AppColors.white, size: 36)),
                  Positioned(
                    left: AppSpacing.sm,
                    bottom: AppSpacing.sm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.gray900.withValues(alpha: 0.55), borderRadius: AppRadii.rSm),
                      child: Text(VideoBubble.formatDuration(durationSec), style: AppText.timestamp.copyWith(color: AppColors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (caption != null && caption!.isNotEmpty) MediaCaption(text: caption!, isMine: isMine),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 3, 4, 2),
            child: BubbleFooter(isMine: isMine, timestamp: timestamp, read: false, status: status),
          ),
        ],
      ),
    );
    return _frame(context, isMine: isMine, bubble: bubble);
  }
}

/// Document message: icon + name + size. Tap → open in-app.
/// A null [getFileUrl] means the file is still in the local outbox (uploading
/// or failed) — same card, status tick from [status], tap does nothing.
class FileBubble extends ConsumerStatefulWidget {
  /// Null while the message is still local: nothing to open yet.
  final String? messageId;
  final String? conversationId;
  final Future<String> Function()? getFileUrl;
  final String fileName;
  final int? fileSizeBytes;
  final bool isMine;
  final DateTime timestamp;
  final bool read;
  final bool delivered;
  final MessageStatus status;
  final String? caption;
  final double? progress;

  /// True → fetch the file in the background so the first tap opens it
  /// instantly (auto-download rule for documents).
  final bool prefetch;

  const FileBubble({
    super.key,
    this.messageId,
    this.conversationId,
    required this.getFileUrl,
    required this.fileName,
    this.fileSizeBytes,
    required this.isMine,
    required this.timestamp,
    this.read = false,
    this.delivered = false,
    this.status = MessageStatus.sent,
    this.caption,
    this.progress,
    this.prefetch = false,
  });

  @override
  ConsumerState<FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends ConsumerState<FileBubble> {
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    final id = widget.messageId;
    final resolve = widget.getFileUrl;
    if (widget.prefetch && id != null && resolve != null) {
      final store = ref.read(chatDocumentStoreProvider);
      store.cached(id).then((f) {
        if (f == null) {
          store.open(id, widget.fileName, resolve, conversationId: widget.conversationId).ignore();
        }
      }).ignore();
    }
  }

  Future<void> _open() async {
    final id = widget.messageId;
    final resolve = widget.getFileUrl;
    if (id == null || resolve == null || _opening) return;
    setState(() => _opening = true);
    await openChatDocument(context, ref, messageId: id, fileName: widget.fileName, resolveUrl: resolve);
    if (mounted) setState(() => _opening = false);
  }

  @override
  Widget build(BuildContext context) {
    final chatTheme = ChatThemeScope.of(context);
    final fg = widget.isMine ? chatTheme.sentFg : chatTheme.receivedFg;
    final sizeLabel = fileSizeLabel(widget.fileSizeBytes);
    final sending = widget.status == MessageStatus.sending;
    final bubble = AppPressable(
      onTap: _open,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.72),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
        decoration: _mediaDecoration(context, widget.isMine),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _opening || sending
                    ? SizedBox(
                        width: 30,
                        height: 30,
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: fg,
                            value: sending && widget.progress != null && widget.progress! > 0 ? widget.progress!.clamp(0.0, 1.0) : null,
                          ),
                        ),
                      )
                    : Icon(Icons.insert_drive_file_outlined, color: fg, size: 30),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.fileName, style: AppText.messageBody.copyWith(color: fg), maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (sizeLabel.isNotEmpty || (sending && widget.progress != null))
                        Text(
                          sending && widget.progress != null
                              ? '${(widget.progress! * 100).clamp(0, 100).round()}%${sizeLabel.isEmpty ? '' : ' · $sizeLabel'}'
                              : sizeLabel,
                          style: AppText.timestamp.copyWith(
                            color: widget.isMine ? fg.withValues(alpha: 0.7) : AppColors.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (widget.caption != null && widget.caption!.isNotEmpty)
              MediaCaption(text: widget.caption!, isMine: widget.isMine, padding: const EdgeInsets.only(top: AppSpacing.xs)),
            const SizedBox(height: 2),
            BubbleFooter(
              isMine: widget.isMine,
              timestamp: widget.timestamp,
              read: widget.read,
              delivered: widget.delivered,
              status: widget.status,
            ),
          ],
        ),
      ),
    );
    return _frame(context, isMine: widget.isMine, bubble: bubble);
  }
}
