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
import '../../widgets/inline_error.dart';
import '../../widgets/link_preview_card.dart';
import '../../widgets/open_document.dart';
import '../../widgets/primary_button.dart';
import '../chat/forward_picker_sheet.dart';
import 'media_viewer_screen.dart';
import '../../../core/utils/async_retry.dart';

/// "Media, links and docs" for one chat (batch 5 E): Media / Docs / Links
/// tabs over `GET /conversations/{id}/media`, a grid viewer, and
/// multi-select → Forward / Delete for me / Star.
const _cancelSelectionLabel = 'Cancel selection';

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
  // Entered from the app bar's Select; long-press on an item also selects.
  bool _selectMode = false;
  bool _busy = false;

  void _exitSelection() {
    _selected.clear();
    _selectMode = false;
  }

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
      setState(_exitSelection);
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
        content: Text(Strings.mediaDeleteForMeBody(messages.length)),
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
      setState(_exitSelection);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _star(List<Message> messages) async {
    setState(() => _busy = true);
    final notifier = ref.read(messagesProvider(widget.conversationId).notifier);
    try {
      for (final m in messages) {
        if (m.starred) continue;
        // Throws when the server refuses; only a star that was really set
        // is drawn on the grid, including when a later one fails.
        await notifier.star(m.id, true);
        for (final n in _notifiers) {
          n.patchStarred({m.id}, true);
        }
      }
      _toast(Strings.chatStarredToast);
      setState(_exitSelection);
    } catch (e) {
      _toast(ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _selectMode || _selected.isNotEmpty;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_exitSelection);
      },
      child: Scaffold(
        appBar: AppBar(
          title: selecting
              ? Text(
                  _selected.isEmpty ? Strings.mediaSelectItems : '${_selected.length}',
                  semanticsLabel: _selected.isEmpty ? null : Strings.a11ySelectedCount(_selected.length),
                )
              : const Text(Strings.mediaGalleryTitle),
          actions: [
            // Selection without the long-press.
            if (!selecting)
              TextButton(
                key: const ValueKey('gallery-select'),
                onPressed: () => setState(() => _selectMode = true),
                child: const Text(Strings.chatSelect),
              ),
          ],
          leading: selecting
              ? IconButton(key: const ValueKey('gallery-cancel-select'), tooltip: _cancelSelectionLabel, icon: const Icon(Icons.close), onPressed: () => setState(_exitSelection))
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
                  _exitSelection();
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
            if (selecting) _SelectionBar(busy: _busy || _selected.isEmpty, onForward: () => _act(_forward), onDelete: () => _act(_deleteForMe), onStar: () => _act(_star)),
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
              // Icon over label, each label scaling down in its third of
              // the bar: three icon+label buttons side by side truncated at
              // large text.
              Expanded(child: _BarAction(key: const ValueKey('gallery-forward'), label: Strings.mediaForward, icon: Icons.shortcut_rounded, color: AppColors.textSecondary, onTap: busy ? null : onForward)),
              Expanded(child: _BarAction(key: const ValueKey('gallery-star'), label: Strings.mediaStar, icon: Icons.star_outline_rounded, color: AppColors.textSecondary, onTap: busy ? null : onStar)),
              Expanded(child: _BarAction(key: const ValueKey('gallery-delete'), label: Strings.chatDelete, icon: Icons.delete_outline_rounded, color: AppColors.red, onTap: busy ? null : onDelete)),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  const _BarAction({super.key, required this.label, required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppPressable(
      minTarget: true,
      enabled: onTap != null,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label, maxLines: 1, softWrap: false, style: AppText.caption.copyWith(color: color, fontWeight: FontWeight.w600)),
            ),
          ],
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
    // Two loads feed one grid. Retry re-asks only for the half that failed.
    void retry() {
      if (images.hasError) {
        ref.invalidate(mediaGalleryProvider((conversationId: conversationId, kind: MediaKind.image)));
      }
      if (videos.hasError) {
        ref.invalidate(mediaGalleryProvider((conversationId: conversationId, kind: MediaKind.video)));
      }
    }

    final failure = images.hasError ? images.error : (videos.hasError ? videos.error : null);
    final items = [...?images.asData?.value, ...?videos.asData?.value]
      ..sort((a, b) => b.message.createdAt.compareTo(a.message.createdAt));
    if (items.isEmpty) {
      // Nothing to show yet: wait while either half is still loading, and a
      // failed half is an error — never "no media" on half an answer.
      if (images.isLoading || videos.isLoading) {
        return const Center(child: CircularProgressIndicator(semanticsLabel: Strings.loading));
      }
      if (failure != null) {
        return _ErrorRetry(message: ErrorMessages.forApi(failure), onRetry: retry);
      }
      return const _Empty(text: Strings.mediaGalleryEmptyMedia, icon: Icons.photo_library_outlined);
    }
    final imgNotifier = ref.read(mediaGalleryProvider((conversationId: conversationId, kind: MediaKind.image)).notifier);
    final vidNotifier = ref.read(mediaGalleryProvider((conversationId: conversationId, kind: MediaKind.video)).notifier);
    final grid = NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
          // A failed page waits for its Retry below rather than being
          // re-asked on every scroll tick.
          if (imgNotifier.hasMore && imgNotifier.loadMoreError == null) imgNotifier.loadMore();
          if (vidNotifier.hasMore && vidNotifier.loadMoreError == null) vidNotifier.loadMore();
        }
        return false;
      },
      child: GridView.builder(
        key: const ValueKey('gallery-grid'),
        // Explicit padding drops the automatic safe-area inset. The selection
        // bar covers the home indicator while it is up; otherwise add it back.
        padding: const EdgeInsets.all(2).copyWith(
          bottom: 2 + (selecting ? 0 : MediaQuery.paddingOf(context).bottom),
        ),
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
            selecting: selecting,
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
    // Older media failed to load: without this the grid just stopped, and
    // looked like the end of the chat's media.
    final moreError = imgNotifier.loadMoreError ?? vidNotifier.loadMoreError;
    final retryingMore = moreError == null &&
        ((images.hasValue && imgNotifier.loadingMore) || (videos.hasValue && vidNotifier.loadingMore));
    if (failure == null && (moreError != null || retryingMore)) {
      return Column(
        children: [
          Expanded(child: grid),
          SafeArea(
            top: false,
            bottom: !selecting,
            child: moreError != null
                ? _LoadMoreFailed(
                    error: moreError,
                    onRetry: () {
                      if (imgNotifier.loadMoreError != null) imgNotifier.loadMore();
                      if (vidNotifier.loadMoreError != null) vidNotifier.loadMore();
                    },
                  )
                : const Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: Strings.loading),
                      ),
                    ),
                  ),
          ),
        ],
      );
    }
    if (failure == null) return grid;
    // One half loaded, the other failed: keep the grid, and say that some
    // media is missing with a way to ask again.
    return Column(
      children: [
        Padding(
          key: const ValueKey('gallery-partial-error'),
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.sm, AppSpacing.xs),
          child: Row(
            children: [
              Expanded(child: InlineError(ErrorMessages.forApi(failure))),
              // The failed half is being asked for again: show that the
              // tap landed instead of an unchanged Retry.
              if ((images.hasError && images.isLoading) || (videos.hasError && videos.isLoading))
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: Strings.loading),
                  ),
                )
              else
                TextButton(
                  key: const ValueKey('gallery-partial-retry'),
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                  onPressed: retry,
                  child: const Text(Strings.retry),
                ),
            ],
          ),
        ),
        Expanded(child: grid),
      ],
    );
  }
}

class _GridTile extends ConsumerStatefulWidget {
  final MediaGalleryItem item;
  final String conversationId;
  final bool selected;

  /// While selecting, a tap always toggles — also on a thumbnail that
  /// failed to load (otherwise a tap there retries it).
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _GridTile({super.key, required this.item, required this.conversationId, required this.selected, required this.selecting, required this.onTap, required this.onLongPress});

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

  void _retry() {
    setState(() => _failed = false);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    // A thumbnail that did not load: the tap fetches it again instead of
    // opening a viewer on a picture that is not there.
    final retryable = _failed && f == null && !widget.selecting;
    return AppPressable(
      onTap: retryable ? _retry : widget.onTap,
      onLongPress: widget.onLongPress,
      semanticLabel: [
        _isVideo
            ? '${Strings.mediaVideo}, ${VideoBubble.formatDuration(_m.voiceDurationSec ?? 0)}'
            : Strings.mediaPhoto,
        if (retryable) Strings.mediaTapToRetry,
        // The star badge is only drawn; say it.
        if (_m.starred) Strings.a11yStarred,
      ].join(', '),
      selected: widget.selected,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (f != null)
            Image.file(f, fit: BoxFit.cover, cacheWidth: 300, errorBuilder: (_, _, _) => Container(color: AppColors.gray100))
          else
            Container(
              color: AppColors.gray100,
              child: _failed
                  ? Icon(
                      retryable ? Icons.refresh_rounded : Icons.broken_image_outlined,
                      key: ValueKey('gallery-tile-failed-${_m.id}'),
                      color: AppColors.gray600,
                    )
                  : null,
            ),
          if (_isVideo)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                    // 0.65, not 0.55: white on this scrim over a white photo is 5.54:1 (was 3.98:1).
                    color: AppColors.gray900.withValues(alpha: 0.65), borderRadius: AppRadii.rXs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_rounded, size: 11, color: AppColors.white),
                    const SizedBox(width: 2),
                    Text(VideoBubble.formatDuration(_m.voiceDurationSec ?? 0), style: AppText.timestamp.copyWith(color: AppColors.white, fontSize: 11)),
                  ],
                ),
              ),
            ),
          if (_m.starred)
            // The star sits on a photo of any colour, so it carries its own
            // white disc: amberText on white is 7.09:1 (amber was 2.15:1).
            Positioned(
              right: 4,
              top: 4,
              child: Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: AppColors.white, shape: BoxShape.circle),
                child: Icon(Icons.star_rounded, size: 14, color: AppColors.amberText),
              ),
            ),
          if (widget.selected)
            Container(
              color: AppColors.medBlue.withValues(alpha: 0.35),
              alignment: Alignment.topLeft,
              padding: const EdgeInsets.all(4),
              // A solid disc behind the tick: white on medBlue is 5.03:1
              // whatever the photo; on the 35% tint alone it was 1.62:1.
              child: Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.medBlue,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.white, width: 1.5),
                ),
                child: const Icon(Icons.check_rounded, color: AppColors.white, size: 15),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _DocsTab extends ConsumerStatefulWidget {
  final String conversationId;
  final Set<String> selected;
  final void Function(String id) onToggle;
  final bool selecting;
  const _DocsTab({required this.conversationId, required this.selected, required this.onToggle, required this.selecting});

  @override
  ConsumerState<_DocsTab> createState() => _DocsTabState();
}

class _DocsTabState extends ConsumerState<_DocsTab> {
  /// Documents being fetched and opened: a second tap on one is ignored, and
  /// its row shows progress in place of the file icon.
  final Set<String> _openingIds = {};

  Future<void> _open(Message m) async {
    if (_openingIds.contains(m.id)) return;
    setState(() => _openingIds.add(m.id));
    try {
      await openChatDocument(context, ref, messageId: m.id, fileName: m.fileName ?? 'File',
          resolveUrl: () => ref.read(chatRepositoryProvider).fileUrl(m.id));
    } finally {
      if (mounted) setState(() => _openingIds.remove(m.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversationId = widget.conversationId;
    final selected = widget.selected;
    final onToggle = widget.onToggle;
    final selecting = widget.selecting;
    final key = (conversationId: conversationId, kind: MediaKind.file);
    final docs = ref.watch(mediaGalleryProvider(key));
    return docs.whenRetrying(
      loading: () => const Center(child: CircularProgressIndicator(semanticsLabel: Strings.loading)),
      error: (e, _) => _ErrorRetry(message: ErrorMessages.forApi(e), onRetry: () => ref.invalidate(mediaGalleryProvider(key))),
      data: (items) {
        if (items.isEmpty) return const _Empty(text: Strings.mediaGalleryEmptyDocs, icon: Icons.description_outlined);
        final notifier = ref.read(mediaGalleryProvider(key).notifier);
        return ListView.builder(
          key: const ValueKey('gallery-docs'),
          itemCount: items.length + (notifier.hasMore ? 1 : 0),
          itemBuilder: (_, i) {
            if (i >= items.length) {
              // The next page failed: say so with a Retry, not a spinner
              // that never stops.
              final moreError = notifier.loadMoreError;
              if (moreError != null) {
                return _LoadMoreFailed(error: moreError, onRetry: notifier.loadMore);
              }
              notifier.loadMore();
              return const Padding(padding: EdgeInsets.all(AppSpacing.md), child: Center(child: CircularProgressIndicator(semanticsLabel: Strings.loading)));
            }
            final m = items[i].message;
            final isSel = selected.contains(m.id);
            return AppPressable(
              key: ValueKey('gallery-doc-${m.id}'),
              selected: isSel,
              onLongPress: () => onToggle(m.id),
              onTap: () {
                if (selecting) {
                  onToggle(m.id);
                } else {
                  _open(m);
                }
              },
              child: Container(
                color: isSel ? AppColors.medBlueLight : null,
                child: ListTile(
                  leading: _openingIds.contains(m.id) && !isSel
                      ? SizedBox(
                          key: ValueKey('gallery-doc-opening-${m.id}'),
                          width: 30,
                          height: 30,
                          child: Padding(
                            padding: const EdgeInsets.all(5),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.medBlue,
                              semanticsLabel: Strings.loading,
                            ),
                          ),
                        )
                      : Icon(isSel ? Icons.check_circle_rounded : Icons.insert_drive_file_outlined, color: AppColors.medBlue, size: 30),
                  title: Text(m.fileName ?? 'File', style: AppText.bodyPrimary, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [fileSizeLabel(m.fileSizeBytes), DateFormat.yMMMd().format(m.createdAt.toLocal())].where((s) => s.isNotEmpty).join(' · '),
                    style: AppText.caption,
                  ),
                  trailing: m.starred ? Icon(Icons.star_rounded, size: 16, color: AppColors.amberText, semanticLabel: Strings.a11yStarred) : null,
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
    return links.whenRetrying(
      loading: () => const Center(child: CircularProgressIndicator(semanticsLabel: Strings.loading)),
      error: (e, _) => _ErrorRetry(message: ErrorMessages.forApi(e), onRetry: () => ref.invalidate(mediaGalleryProvider(key))),
      data: (items) {
        if (items.isEmpty) return const _Empty(text: Strings.mediaGalleryEmptyLinks, icon: Icons.link_rounded);
        final notifier = ref.read(mediaGalleryProvider(key).notifier);
        return ListView.builder(
          key: const ValueKey('gallery-links'),
          // As on the media grid: the home-indicator inset, unless the
          // selection bar is covering it.
          padding: EdgeInsets.only(
            top: AppSpacing.sm,
            bottom: AppSpacing.sm + (selecting ? 0 : MediaQuery.paddingOf(context).bottom),
          ),
          itemCount: items.length + (notifier.hasMore ? 1 : 0),
          itemBuilder: (_, i) {
            if (i >= items.length) {
              // The next page failed: say so with a Retry, not a spinner
              // that never stops.
              final moreError = notifier.loadMoreError;
              if (moreError != null) {
                return _LoadMoreFailed(error: moreError, onRetry: notifier.loadMore);
              }
              notifier.loadMore();
              return const Padding(padding: EdgeInsets.all(AppSpacing.md), child: Center(child: CircularProgressIndicator(semanticsLabel: Strings.loading)));
            }
            final it = items[i];
            final m = it.message;
            final isSel = selected.contains(m.id);
            final url = it.urls.isNotEmpty ? it.urls.first : null;
            return AppPressable(
              key: ValueKey('gallery-link-${m.id}'),
              selected: isSel,
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The row tint alone is 1.10:1; the check says it too.
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.md, top: AppSpacing.xs),
                      child: Icon(isSel ? Icons.check_circle_rounded : Icons.link_rounded, color: AppColors.medBlue),
                    ),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (url != null) LinkPreviewCard(url: url, isMine: false, width: double.infinity),
                            const SizedBox(height: AppSpacing.xs),
                            Text(url ?? (m.content ?? ''), // medBlue on the selected medBlueLight row is 4.36:1;
                                // tealBadgeText is 5.53:1 there.
                                style: AppText.caption.copyWith(color: isSel ? AppColors.tealBadgeText : AppColors.medBlue), maxLines: 2, overflow: TextOverflow.ellipsis),
                            Text(DateFormat.yMMMd().format(m.createdAt.toLocal()), style: AppText.timestamp.copyWith(color: AppColors.textMuted)),
                          ],
                      ),
                    ),
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

/// Under the rows when the next page failed to load: the reason and a Retry.
class _LoadMoreFailed extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _LoadMoreFailed({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('gallery-more-error'),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InlineError(ErrorMessages.forApi(error)),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            key: const ValueKey('gallery-more-retry'),
            label: Strings.retry,
            icon: Icons.refresh_rounded,
            variant: AppButtonVariant.ghost,
            expand: true,
            onPressed: onRetry,
          ),
        ],
      ),
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
          // Announced when it replaces the loading state.
          Semantics(
            container: true,
            liveRegion: true,
            child: Text(text, key: const ValueKey('gallery-empty'), style: AppText.caption),
          ),
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
          // Announced when it replaces the loading state.
          Semantics(
            container: true,
            liveRegion: true,
            child: Text(message, style: AppText.caption),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: Strings.retry, variant: AppButtonVariant.secondary, onPressed: onRetry),
        ],
      ),
    );
  }
}
