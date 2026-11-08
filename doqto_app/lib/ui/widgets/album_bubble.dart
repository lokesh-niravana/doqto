import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/strings.dart';
import '../../core/di/providers.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../data/models/message.dart';
import '../../data/services/chat_media_cache.dart';
import 'app_pressable.dart';
import 'attachment_bubbles.dart';

/// Two to many consecutive photos from one sender drawn as one tile grid
/// (batch 5 B). [messages] come newest-first as the thread keeps them; the
/// grid shows them in send order. Up to four tiles, the fourth carrying
/// "+N" for the rest. The caption of the last photo sent sits under the grid.
class AlbumBubble extends ConsumerWidget {
  final List<Message> messages;
  final String conversationId;
  final bool isMine;
  final Future<String> Function(Message m) resolveUrl;
  final void Function(int index) onOpen;
  final bool autoDownload;

  const AlbumBubble({
    super.key,
    required this.messages,
    required this.conversationId,
    required this.isMine,
    required this.resolveUrl,
    required this.onOpen,
    this.autoDownload = true,
  });

  static const maxTiles = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ordered = messages.reversed.toList(growable: false);
    final newest = messages.first;
    final maxW = MediaQuery.sizeOf(context).width * 0.72;
    // Inner width: bubble padding on both sides, plus the 1 px border a
    // received bubble draws.
    final w = maxW - 8 - (isMine ? 0 : 2);
    const gap = 2.0;
    final n = ordered.length;
    final extra = n - maxTiles;
    final caption = ordered.lastWhere((m) => (m.caption ?? '').isNotEmpty, orElse: () => newest).caption;

    Widget tile(int i, double tw, double th, {String? badge}) => _AlbumTile(
          key: ValueKey('album-tile-${ordered[i].id}'),
          message: ordered[i],
          conversationId: conversationId,
          width: tw,
          height: th,
          resolveUrl: () => resolveUrl(ordered[i]),
          onTap: () => onOpen(i),
          badge: badge,
          autoDownload: autoDownload,
        );

    final half = (w - gap) / 2;
    final Widget grid;
    if (n == 2) {
      grid = Row(children: [tile(0, half, half), const SizedBox(width: gap), tile(1, half, half)]);
    } else if (n == 3) {
      grid = Column(children: [
        tile(0, w, half),
        const SizedBox(height: gap),
        Row(children: [tile(1, half, half), const SizedBox(width: gap), tile(2, half, half)]),
      ]);
    } else {
      grid = Column(children: [
        Row(children: [tile(0, half, half), const SizedBox(width: gap), tile(1, half, half)]),
        const SizedBox(height: gap),
        Row(children: [
          tile(2, half, half),
          const SizedBox(width: gap),
          tile(3, half, half, badge: extra > 0 ? '+$extra' : null),
        ]),
      ]);
    }

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
          ClipRRect(borderRadius: AppRadii.rMd, child: grid),
          if (caption != null && caption.isNotEmpty) MediaCaption(text: caption, isMine: isMine),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 3, 4, 2),
            child: BubbleFooter(
              isMine: isMine,
              timestamp: newest.createdAt.toLocal(),
              read: messages.every((m) => m.read),
              delivered: messages.every((m) => m.delivered),
              status: messages.any((m) => m.status == MessageStatus.failed)
                  ? MessageStatus.failed
                  : messages.any((m) => m.status == MessageStatus.sending)
                      ? MessageStatus.sending
                      : MessageStatus.sent,
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [bubble],
      ),
    );
  }
}

class _AlbumTile extends ConsumerStatefulWidget {
  final Message message;
  final String conversationId;
  final double width;
  final double height;
  final Future<String> Function() resolveUrl;
  final VoidCallback onTap;
  final String? badge;
  final bool autoDownload;
  const _AlbumTile({
    super.key,
    required this.message,
    required this.conversationId,
    required this.width,
    required this.height,
    required this.resolveUrl,
    required this.onTap,
    required this.autoDownload,
    this.badge,
  });

  @override
  ConsumerState<_AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends ConsumerState<_AlbumTile> {
  late final ChatMediaCache _cache = ref.read(chatMediaCacheProvider);
  File? _file;
  bool _failed = false;
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    final m = widget.message;
    if (m.localPath != null && m.status != MessageStatus.sent) {
      _file = File(m.localPath!);
      return;
    }
    _file = _cache.peek(m.id);
    if (_file == null) {
      if (widget.autoDownload) {
        _load();
      } else {
        _waiting = true;
        _cache.cached(m.id).then((f) {
          if (f != null && mounted) {
            setState(() {
              _file = f;
              _waiting = false;
            });
          }
        });
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _failed = false;
      _waiting = false;
    });
    try {
      final f = await _cache.image(widget.message.id, widget.resolveUrl, conversationId: widget.conversationId);
      if (mounted) setState(() => _file = f);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final sending = widget.message.status == MessageStatus.sending;
    final Widget body;
    if (_failed) {
      body = AppPressable(
        onTap: _load,
        child: Container(color: AppColors.gray100, child: const Icon(Icons.broken_image_outlined, color: AppColors.gray400)),
      );
    } else if (file == null && _waiting) {
      body = DownloadPlaceholder(width: widget.width, height: widget.height, label: '', onTap: _load);
    } else if (file == null) {
      body = Container(color: AppColors.gray100, child: const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))));
    } else {
      body = AppPressable(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Opacity(
              opacity: sending ? 0.7 : 1,
              child: Image.file(
                file,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: (widget.width * MediaQuery.devicePixelRatioOf(context)).round(),
                errorBuilder: (_, _, _) => Container(color: AppColors.gray100),
              ),
            ),
            if (widget.badge != null)
              Container(
                color: AppColors.gray900.withValues(alpha: 0.55),
                alignment: Alignment.center,
                child: Text(widget.badge!, key: const ValueKey('album-more'), style: AppText.heading.copyWith(color: AppColors.white)),
              )
            else if (sending)
              const Center(child: UploadRing()),
          ],
        ),
      );
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Semantics(label: Strings.mediaPhoto, child: body),
    );
  }
}
