import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/media.dart';
import '../../../data/models/message.dart';
import '../../../state/chat_state.dart';
import '../../../state/media_gallery_state.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/attachment_bubbles.dart';
import '../../widgets/external_link_confirm.dart';
import '../../widgets/link_preview_card.dart';
import '../../widgets/open_document.dart';
import '../../widgets/primary_button.dart';
import '../chat/forward_picker_sheet.dart';
import 'media_viewer_screen.dart';

/// "Media, links and docs" for one chat (batch 5 E): Media / Docs / Links
/// tabs over `GET /conversations/{id}/media`, a grid viewer, and
/// multi-select → Forward / Delete for me / Star.
class MediaGalleryScreen extends ConsumerStatefulWidget {
  final String conversationId;
  final int initialTab;
  const MediaGalleryScreen({super.key, required this.conversationId, this.initialTab = 0});

  @override
  ConsumerState<MediaGalleryScreen> createState() => _MediaGalleryScreenState();
}

class _MediaGalleryScreenState extends ConsumerState<MediaGalleryScreen> {
  late int _tab = widget.initialTab;
  final _selected = <String>{};
  bool _busy = false;

  GalleryKey _key(MediaKind k) => (conversationId: widget.conversationId, kind: k);

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  List<MediaGalleryNotifier> get _notifiers => [
        for (final k in MediaKind.values) ref.read(mediaGalleryProvider(_key(k)).notifier),
      ];

  Future<void> _forward(List<Message> messages) async {
    final targets = await showForwardPicker(context, excludeConversationId: widget.conversationId);
    if (targets == null || targets.isEmpty || !mounted) return;
    setState(() => _busy = true);
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
      await ref.read(messagesProvider(widget.conversationId).notifier).forward([for (final m in messages) m.id], convIds);
      _toast(Strings.chatForwardedToast);
      setState(_selected.clear);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteForMe(List<Message> messages) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Strings.mediaDeleteForMe),
        content: Text('${messages.length}'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text(Strings.cancel)),
          TextButton(
            key: const ValueKey('gallery-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(Strings.chatDelete, style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final ids = {for (final m in messages) m.id};
    try {
      await ref.read(messagesProvider(widget.conversationId).notifier).hide(ids.toList());
      for (final n in _notifiers) {
        n.remove(ids);
      }
      setState(_selected.clear);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _star(List<Message> messages) async {
    setState(() => _busy = true);
    final notifier = ref.read(messagesProvider(widget.conversationId).notifier);
    final ids = {for (final m in messages) m.id};
    try {
      for (final m in messages) {
        if (!m.starred) await notifier.star(m.id, true);
      }
      for (final n in _notifiers) {
        n.patchStarred(ids, true);
      }
      _toast(Strings.chatStarredToast);
      setState(_selected.clear);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(selecting ? '${_selected.length}' : Strings.mediaGalleryTitle),
          leading: selecting
              ? IconButton(key: const ValueKey('gallery-cancel-select'), icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear))
              : null,
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
              child: AppSegmented(
                key: const ValueKey('gallery-tabs'),
                tabs: const [Strings.mediaTabMedia, Strings.mediaTabDocs, Strings.mediaTabLinks],
                index: _tab,
                onChanged: (i) => setState(() {
                  _tab = i;
                  _selected.clear();
                }),
              ),
            ),
            Expanded(
              child: switch (_tab) {
                0 => _MediaTab(
                    conversationId: widget.conversationId,
                    selected: _selected,
                    onToggle: _toggle,
                    selecting: selecting,
                  ),
                1 => _DocsTab(conversationId: widget.conversationId, selected: _selected, onToggle: _toggle, selecting: selecting),
                _ => _LinksTab(conversationId: widget.conversationId, selected: _selected, onToggle: _toggle, selecting: selecting),
              },
            ),
            if (selecting) _SelectionBar(busy: _busy, onForward: () => _act(_forward), onDelete: () => _act(_deleteForMe), onStar: () => _act(_star)),
          ],
        ),
      ),
    );
  }

  void _act(Future<void> Function(List<Message>) fn) {
    final all = <Message>[];
    for (final k in MediaKind.values) {
      final items = ref.read(mediaGalleryProvider(_key(k))).asData?.value ?? const [];
      all.addAll(items.map((i) => i.message));
    }
    final picked = [for (final m in all) if (_selected.contains(m.id)) m];
    final seen = <String>{};
    final unique = [for (final m in picked) if (seen.add(m.id)) m];
    if (unique.isEmpty) return;
    fn(unique);
  }
}

class _SelectionBar extends StatelessWidget {
  final bool busy;
  final VoidCallback onForward;
  final VoidCallback onDelete;
  final VoidCallback onStar;
  const _SelectionBar({required this.busy, required this.onForward, required this.onDelete, required this.onStar});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          child: Row(
            children: [
              Expanded(child: AppButton(key: const ValueKey('gallery-forward'), label: Strings.mediaForward, icon: Icons.shortcut_rounded, variant: AppButtonVariant.ghost, onPressed: busy ? null : onForward)),
              Expanded(child: AppButton(key: const ValueKey('gallery-star'), label: Strings.mediaStar, icon: Icons.star_outline_rounded, variant: AppButtonVariant.ghost, onPressed: busy ? null : onStar)),
              Expanded(child: AppButton(key: const ValueKey('gallery-delete'), label: Strings.chatDelete, icon: Icons.delete_outline_rounded, variant: AppButtonVariant.danger, onPressed: busy ? null : onDelete)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _MediaTab extends ConsumerWidget {
  final String conversationId;
  final Set<String> selected;
  final void Function(String id) onToggle;
  final bool selecting;
  const _MediaTab({required this.conversationId, required this.selected, required this.onToggle, required this.selecting});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = ref.watch(mediaGalleryProvider((conversationId: conversationId, kind: MediaKind.image)));
    final videos = ref.watch(mediaGalleryProvider((conversationId: conversationId, kind: MediaKind.video)));
    if (images.isLoading && videos.isLoading) return const Center(child: CircularProgressIndicator());
    if (images.hasError && videos.hasError) {
      return _ErrorRetry(
        message: ErrorMessages.forApi(images.error!),
        onRetry: () {
          ref.invalidate(mediaGalleryProvider((conversationId: conversationId, kind: MediaKind.image)));
          ref.invalidate(mediaGalleryProvider((conversationId: conversationId, kind: MediaKind.video)));
        },
      );
    }
    final items = [...?images.asData?.value, ...?videos.asData?.value]
      ..sort((a, b) => b.message.createdAt.compareTo(a.message.createdAt));
    if (items.isEmpty) return const _Empty(text: Strings.mediaGalleryEmptyMedia, icon: Icons.photo_library_outlined);
    final imgNotifier = ref.read(mediaGalleryProvider((conversationId: conversationId, kind: MediaKind.image)).notifier);
    final vidNotifier = ref.read(mediaGalleryProvider((conversationId: conversationId, kind: MediaKind.video)).notifier);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
          if (imgNotifier.hasMore) imgNotifier.loadMore();
          if (vidNotifier.hasMore) vidNotifier.loadMore();
        }
        return false;
      },
      child: GridView.builder(
        key: const ValueKey('gallery-grid'),
        padding: const EdgeInsets.all(2),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final it = items[i];
          final m = it.message;
          final isSel = selected.contains(m.id);
          return _GridTile(
            key: ValueKey('gallery-tile-${m.id}'),
            item: it,
            conversationId: conversationId,
            selected: isSel,
            onLongPress: () => onToggle(m.id),
            onTap: () {
              if (selecting) {
                onToggle(m.id);
              } else {
                MediaViewerScreen.open(context, conversationId: conversationId, items: [for (final x in items) x.message], initialIndex: i);
              }
            },
          );
        },
      ),
    );
  }
}

class _GridTile extends ConsumerStatefulWidget {
  final MediaGalleryItem item;
  final String conversationId;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _GridTile({super.key, required this.item, required this.conversationId, required this.selected, required this.onTap, required this.onLongPress});

  @override
  ConsumerState<_GridTile> createState() => _GridTileState();
}

class _GridTileState extends ConsumerState<_GridTile> {
  File? _file;
  bool _failed = false;

  Message get _m => widget.item.message;
  bool get _isVideo => _m.type == MessageType.video;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cache = ref.read(chatMediaCacheProvider);
    final repo = ref.read(chatRepositoryProvider);
    try {
      final f = _isVideo
          ? await cache.thumbnail(_m.id, () => repo.fileUrl(_m.id, thumb: true), conversationId: widget.conversationId)
          : await cache.image(
              _m.id,
              () async => widget.item.urls.isNotEmpty ? widget.item.urls.first : repo.fileUrl(_m.id),
              conversationId: widget.conversationId,
            );
      if (mounted) setState(() => _file = f);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    return AppPressable(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (f != null)
            Image.file(f, fit: BoxFit.cover, cacheWidth: 300, errorBuilder: (_, _, _) => Container(color: AppColors.gray100))
          else
            Container(
              color: AppColors.gray100,
              child: _failed ? Icon(Icons.broken_image_outlined, color: AppColors.gray400) : null,
            ),
          if (_isVideo)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: AppColors.gray900.withValues(alpha: 0.55), borderRadius: AppRadii.rXs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_rounded, size: 11, color: AppColors.white),
                    const SizedBox(width: 2),
                    Text(VideoBubble.formatDuration(_m.voiceDurationSec ?? 0), style: AppText.timestamp.copyWith(color: AppColors.white, fontSize: 10)),
                  ],
                ),
              ),
            ),
          if (_m.starred)
            const Positioned(right: 4, top: 4, child: Icon(Icons.star_rounded, size: 14, color: AppColors.amber)),
          if (widget.selected)
            Container(
              color: AppColors.medBlue.withValues(alpha: 0.35),
              alignment: Alignment.topLeft,
              padding: const EdgeInsets.all(4),
              child: const Icon(Icons.check_circle_rounded, color: AppColors.white, size: 20),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _DocsTab extends ConsumerWidget {
  final String conversationId;
  final Set<String> selected;
  final void Function(String id) onToggle;
  final bool selecting;
  const _DocsTab({required this.conversationId, required this.selected, required this.onToggle, required this.selecting});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (conversationId: conversationId, kind: MediaKind.file);
    final docs = ref.watch(mediaGalleryProvider(key));
    return docs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorRetry(message: ErrorMessages.forApi(e), onRetry: () => ref.invalidate(mediaGalleryProvider(key))),
      data: (items) {
        if (items.isEmpty) return const _Empty(text: Strings.mediaGalleryEmptyDocs, icon: Icons.description_outlined);
        final notifier = ref.read(mediaGalleryProvider(key).notifier);
        return ListView.builder(
          key: const ValueKey('gallery-docs'),
          itemCount: items.length + (notifier.hasMore ? 1 : 0),
          itemBuilder: (_, i) {
            if (i >= items.length) {
              notifier.loadMore();
              return const Padding(padding: EdgeInsets.all(AppSpacing.md), child: Center(child: CircularProgressIndicator()));
            }
            final m = items[i].message;
            final isSel = selected.contains(m.id);
            return AppPressable(
              key: ValueKey('gallery-doc-${m.id}'),
              onLongPress: () => onToggle(m.id),
              onTap: () {
                if (selecting) {
                  onToggle(m.id);
                } else {
                  openChatDocument(context, ref, messageId: m.id, fileName: m.fileName ?? 'File',
                      resolveUrl: () => ref.read(chatRepositoryProvider).fileUrl(m.id));
                }
              },
              child: Container(
                color: isSel ? AppColors.medBlueLight : null,
                child: ListTile(
                  leading: Icon(isSel ? Icons.check_circle_rounded : Icons.insert_drive_file_outlined, color: AppColors.medBlue, size: 30),
                  title: Text(m.fileName ?? 'File', style: AppText.bodyPrimary, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [fileSizeLabel(m.fileSizeBytes), DateFormat.yMMMd().format(m.createdAt.toLocal())].where((s) => s.isNotEmpty).join(' · '),
                    style: AppText.caption,
                  ),
                  trailing: m.starred ? const Icon(Icons.star_rounded, size: 16, color: AppColors.amber) : null,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------

class _LinksTab extends ConsumerWidget {
  final String conversationId;
  final Set<String> selected;
  final void Function(String id) onToggle;
  final bool selecting;
  const _LinksTab({required this.conversationId, required this.selected, required this.onToggle, required this.selecting});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (conversationId: conversationId, kind: MediaKind.link);
    final links = ref.watch(mediaGalleryProvider(key));
    return links.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorRetry(message: ErrorMessages.forApi(e), onRetry: () => ref.invalidate(mediaGalleryProvider(key))),
      data: (items) {
        if (items.isEmpty) return const _Empty(text: Strings.mediaGalleryEmptyLinks, icon: Icons.link_rounded);
        final notifier = ref.read(mediaGalleryProvider(key).notifier);
        return ListView.builder(
          key: const ValueKey('gallery-links'),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          itemCount: items.length + (notifier.hasMore ? 1 : 0),
          itemBuilder: (_, i) {
            if (i >= items.length) {
              notifier.loadMore();
              return const Padding(padding: EdgeInsets.all(AppSpacing.md), child: Center(child: CircularProgressIndicator()));
            }
            final it = items[i];
            final m = it.message;
            final isSel = selected.contains(m.id);
            final url = it.urls.isNotEmpty ? it.urls.first : null;
            return AppPressable(
              key: ValueKey('gallery-link-${m.id}'),
              onLongPress: () => onToggle(m.id),
              onTap: () {
                if (selecting) {
                  onToggle(m.id);
                } else if (url != null) {
                  confirmAndOpenExternal(context, url: url, opener: ref.read(urlOpenerProvider));
                }
              },
              child: Container(
                color: isSel ? AppColors.medBlueLight : null,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (url != null) LinkPreviewCard(url: url, isMine: false, width: double.infinity),
                    const SizedBox(height: AppSpacing.xs),
                    Text(url ?? (m.content ?? ''), style: AppText.caption.copyWith(color: AppColors.medBlue), maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(DateFormat.yMMMd().format(m.createdAt.toLocal()), style: AppText.timestamp.copyWith(color: AppColors.textMuted)),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Empty({required this.text, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: AppColors.gray400),
          const SizedBox(height: AppSpacing.sm),
          Text(text, key: const ValueKey('gallery-empty'), style: AppText.caption),
        ],
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: AppText.caption),
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: Strings.retry, variant: AppButtonVariant.secondary, onPressed: onRetry),
        ],
      ),
    );
  }
}
