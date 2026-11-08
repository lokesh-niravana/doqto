import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/message.dart';
import '../../../state/chat_state.dart';
import '../../widgets/app_pressable.dart';
import '../chat/forward_picker_sheet.dart';
import 'video_player_screen.dart';

/// Full-screen pager over the photos and videos of a chat (batch 5 F).
/// Save to Photos and Share appear only when the conversation allows media
/// export; each writes an export-audit row first and bails when the server
/// says `media_export_blocked`.
class MediaViewerScreen extends ConsumerStatefulWidget {
  final String conversationId;
  final List<Message> items;
  final int initialIndex;

  const MediaViewerScreen({
    super.key,
    required this.conversationId,
    required this.items,
    this.initialIndex = 0,
  });

  /// Push over everything (the thread, the gallery, the shell).
  static Future<void> open(
    BuildContext context, {
    required String conversationId,
    required List<Message> items,
    int initialIndex = 0,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => MediaViewerScreen(conversationId: conversationId, items: items, initialIndex: initialIndex),
      ),
    );
  }

  @override
  ConsumerState<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends ConsumerState<MediaViewerScreen> {
  late final PageController _pager = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _busy = false;
  bool _chrome = true;

  Message get _current => widget.items[_index];

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<String> _url(Message m) => ref.read(chatRepositoryProvider).fileUrl(m.id);

  Future<File> _fileFor(Message m) async {
    final cache = ref.read(chatMediaCacheProvider);
    return cache.media(m.id, () => _url(m), conversationId: widget.conversationId);
  }

  /// Export audit, then the file; null when the server blocked it.
  Future<File?> _exportable(Message m) async {
    try {
      await ref.read(chatRepositoryProvider).exportAudit(m.id);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
      return null;
    }
    return _fileFor(m);
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final f = await _exportable(_current);
      if (f == null) return;
      final ok = await ref.read(mediaNativeProvider).saveToPhotos(f.path);
      _toast(ok ? Strings.mediaSaved : Strings.mediaSaveFailed);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final f = await _exportable(_current);
      if (f == null) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: _current.caption));
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forward() async {
    final targets = await showForwardPicker(context, excludeConversationId: widget.conversationId);
    if (targets == null || targets.isEmpty || !mounted) return;
    try {
      final repo = ref.read(chatRepositoryProvider);
      final convIds = <String>[];
      for (final t in targets) {
        if (t.conversationId != null) {
          convIds.add(t.conversationId!);
        } else if (t.userId != null) {
          final c = await repo.createConversation(type: ConversationType.direct, name: null, memberIds: [t.userId!]);
          convIds.add(c.id);
        }
      }
      await ref.read(messagesProvider(widget.conversationId).notifier).forward([_current.id], convIds);
      _toast(Strings.chatForwardedToast);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    }
  }

  Future<void> _star() async {
    final m = _current;
    try {
      await ref.read(messagesProvider(widget.conversationId).notifier).star(m.id, !m.starred);
      _toast(m.starred ? Strings.chatUnstarredToast : Strings.chatStarredToast);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final exportAllowed = ref.watch(mediaExportAllowedProvider(widget.conversationId));
    // Live star state, if the thread has this message loaded.
    final live = ref.watch(messagesProvider(widget.conversationId)).asData?.value
        .where((m) => m.id == _current.id).firstOrNull;
    final starred = live?.starred ?? _current.starred;
    final m = _current;
    return Scaffold(
      backgroundColor: AppColors.gray900,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            key: const ValueKey('media-viewer-pager'),
            controller: _pager,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => _Page(
              key: ValueKey('media-page-${widget.items[i].id}'),
              message: widget.items[i],
              conversationId: widget.conversationId,
              resolveUrl: () => _url(widget.items[i]),
              onTap: () => setState(() => _chrome = !_chrome),
            ),
          ),
          AnimatedOpacity(
            opacity: _chrome ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !_chrome,
              child: Column(
                children: [
                  Container(
                    color: AppColors.gray900.withValues(alpha: 0.6),
                    child: SafeArea(
                      bottom: false,
                      child: Row(
                        children: [
                          IconButton(
                            key: const ValueKey('viewer-close'),
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close, color: AppColors.white),
                          ),
                          Expanded(
                            child: Text(
                              '${_index + 1} / ${widget.items.length}',
                              key: const ValueKey('viewer-index'),
                              style: AppText.label.copyWith(color: AppColors.white),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('viewer-star'),
                            onPressed: _star,
                            icon: Icon(starred ? Icons.star_rounded : Icons.star_outline_rounded,
                                color: starred ? AppColors.amber : AppColors.white),
                          ),
                          if (m.canForward)
                            IconButton(
                              key: const ValueKey('viewer-forward'),
                              onPressed: _forward,
                              icon: const Icon(Icons.shortcut_rounded, color: AppColors.white),
                            ),
                          if (exportAllowed) ...[
                            IconButton(
                              key: const ValueKey('viewer-save'),
                              tooltip: Strings.mediaSaveToPhotos,
                              onPressed: _busy ? null : _save,
                              icon: const Icon(Icons.download_rounded, color: AppColors.white),
                            ),
                            IconButton(
                              key: const ValueKey('viewer-share'),
                              tooltip: Strings.mediaShare,
                              onPressed: _busy ? null : _share,
                              icon: const Icon(Icons.ios_share_rounded, color: AppColors.white),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  if ((m.caption ?? '').isNotEmpty)
                    Container(
                      width: double.infinity,
                      color: AppColors.gray900.withValues(alpha: 0.6),
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          child: Text(m.caption!, key: const ValueKey('viewer-caption'), style: AppText.body.copyWith(color: AppColors.white)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_busy) const Center(child: CircularProgressIndicator(color: AppColors.white)),
        ],
      ),
    );
  }
}

class _Page extends ConsumerStatefulWidget {
  final Message message;
  final String conversationId;
  final Future<String> Function() resolveUrl;
  final VoidCallback onTap;
  const _Page({super.key, required this.message, required this.conversationId, required this.resolveUrl, required this.onTap});

  @override
  ConsumerState<_Page> createState() => _PageState();
}

class _PageState extends ConsumerState<_Page> {
  File? _file;
  bool _failed = false;

  bool get _isVideo => widget.message.type == MessageType.video;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cache = ref.read(chatMediaCacheProvider);
    final m = widget.message;
    try {
      if (_isVideo) {
        // The poster is enough to draw the page; the clip loads in the player.
        final f = m.localThumbPath != null
            ? File(m.localThumbPath!)
            : await cache.thumbnail(m.id, () => ref.read(chatRepositoryProvider).fileUrl(m.id, thumb: true),
                conversationId: widget.conversationId);
        if (mounted) setState(() => _file = f);
      } else {
        final f = m.localPath != null && m.status != MessageStatus.sent
            ? File(m.localPath!)
            : await cache.image(m.id, widget.resolveUrl, conversationId: widget.conversationId);
        if (mounted) setState(() => _file = f);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _play() async {
    final cache = ref.read(chatMediaCacheProvider);
    final cached = await cache.cached(widget.message.id);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => VideoPlayerScreen(
        file: cached,
        resolveUrl: cached == null ? widget.resolveUrl : null,
        caption: widget.message.caption,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    if (_failed) {
      return const Center(child: Icon(Icons.broken_image_outlined, color: AppColors.gray400, size: 48));
    }
    if (f == null) return const Center(child: CircularProgressIndicator(color: AppColors.white));
    if (_isVideo) {
      return GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: Image.file(f, fit: BoxFit.contain)),
            Center(
              child: AppPressable(
                key: ValueKey('viewer-play-${widget.message.id}'),
                onTap: _play,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(color: AppColors.gray900.withValues(alpha: 0.6), shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow_rounded, color: AppColors.white, size: 44),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: widget.onTap,
      child: InteractiveViewer(
        key: ValueKey('viewer-image-${widget.message.id}'),
        maxScale: 5,
        child: Center(child: Image.file(f, fit: BoxFit.contain)),
      ),
    );
  }
}
