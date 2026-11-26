import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/chat_theme.dart';
import '../../../core/constants/strings.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/conversation_prefs.dart';
import '../../../data/services/wallpaper_store.dart';
import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/settings_state.dart';

/// Wallpaper picker (batch 6): 8 painted patterns, solid colours, an own
/// photo (kept on this device only — the server stores the marker `local`)
/// or none, with a live preview on top. No
/// [conversationId] = device default; otherwise `prefs.wallpaper` per chat.
class WallpaperPickerScreen extends ConsumerStatefulWidget {
  final String? conversationId;
  const WallpaperPickerScreen({super.key, this.conversationId});

  @override
  ConsumerState<WallpaperPickerScreen> createState() => _WallpaperPickerScreenState();
}

class _WallpaperPickerScreenState extends ConsumerState<WallpaperPickerScreen> {

  @override
  void dispose() {
    super.dispose();
  }

  String get _photoKey => widget.conversationId ?? WallpaperStore.defaultKey;

  Future<void> _apply(String? id) async {
    final convId = widget.conversationId;
    if (convId == null) {
      await ref.read(appSettingsProvider.notifier).setWallpaper(id);
      return;
    }
    final notifier = ref.read(conversationsProvider.notifier);
    final prefs = notifier.conversation(convId)?.prefs ?? ConversationPrefs.defaults;
    try {
      await notifier.setPrefs(
        convId,
        optimistic: prefs.copyWith(wallpaper: () => id),
        patch: {'wallpaper': id},
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessages.forApi(e))),
      );
    }
  }

  Future<void> _pickPhoto() async {
    try {
      final store = await ref.read(wallpaperStoreProvider.future);
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (picked == null) return;
      await store.save(_photoKey, File(picked.path));
      ref.invalidate(wallpaperPhotoProvider);
      await _apply(WallpaperSpec.localId);
    } on PlatformException catch (e) {
      if (!mounted) return;
      // image_picker's code for photo access turned off in Settings: say so
      // and offer the way there, instead of a generic failure.
      final denied = e.code == 'photo_access_denied';
      ScaffoldMessenger.of(context).showSnackBar(
        denied
            ? SnackBar(
                content: const Text(Strings.photoAccessOffBody),
                action: SnackBarAction(
                  label: Strings.openSettings,
                  onPressed: openAppSettings,
                ),
              )
            : SnackBar(
                content: Text(ErrorMessages.forApi(e)),
                backgroundColor: AppColors.red,
              ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = ref.watch(appSettingsProvider);
    final convId = widget.conversationId;
    final conv = convId == null
        ? null
        : ref.watch(conversationsProvider).asData?.value.where((c) => c.id == convId).firstOrNull;
    final String? currentId = convId == null ? settings.wallpaper : conv?.prefs.wallpaper;
    final preview = ChatThemeResolver.resolve(
      chatTheme: conv?.prefs.theme,
      wallpaper: currentId,
      defaultTheme: settings.chatTheme,
      defaultWallpaper: convId == null ? null : settings.wallpaper,
      localPhoto: ref.watch(wallpaperPhotoProvider(_photoKey)),
    );
    final ink = preview.patternInk;

    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.wallpaperTitle)),
      body: ListView(
        key: const ValueKey('wallpaper-list'),
        // Explicit padding drops the automatic safe-area inset; add it back so
        // the last row clears the home indicator.
        padding: EdgeInsets.only(bottom: AppSpacing.xl + MediaQuery.paddingOf(context).bottom),
        children: [
          // Live preview.
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
            child: ClipRRect(
              borderRadius: AppRadii.rLg,
              // At least 180pt, taller when the sample bubbles wrap at a
              // large text size (a fixed height clipped them). The wallpaper
              // fills whatever height the bubbles end up needing.
              child: Stack(
                key: const ValueKey('wallpaper-preview'),
                children: [
                  Positioned.fill(
                    child: ChatWallpaperBackground(
                      data: preview,
                      child: const SizedBox.shrink(),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: 180,
                      minWidth: double.infinity,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: _Bubble(
                              text: l.chatThemeReceived,
                              bg: preview.receivedBg,
                              fg: preview.receivedFg,
                              radius: AppRadii.bubbleReceived,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Align(
                            alignment: Alignment.centerRight,
                            child: _Bubble(
                              text: l.chatThemeSent,
                              bg: preview.sentBg,
                              fg: preview.sentFg,
                              radius: AppRadii.bubbleSent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _Header(l.wallpaperPatterns),
          _Grid(
            labelled: true,
            children: [
              for (final p in WallpaperPattern.values)
                _Tile(
                  key: ValueKey('wallpaper-pattern-${p.name}'),
                  selected: currentId == p.id,
                  label: p.label,
                  onTap: () => _apply(p.id),
                  child: CustomPaint(
                    painter: WallpaperPainter(p, ink),
                    child: const SizedBox.expand(),
                  ),
                ),
            ],
          ),
          _Header(l.wallpaperSolids),
          _Grid(
            children: [
              for (var i = 0; i < WallpaperSpec.solids.length; i++)
                _Tile(
                  key: ValueKey('wallpaper-solid-$i'),
                  selected: currentId == WallpaperSpec.solidId(WallpaperSpec.solids[i]),
                  semanticLabel: Strings.wallpaperSolidName(i),
                  onTap: () => _apply(WallpaperSpec.solidId(WallpaperSpec.solids[i])),
                  child: ColoredBox(color: WallpaperSpec.solids[i]),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ListTile(
            key: const ValueKey('wallpaper-photo'),
            selected: currentId == WallpaperSpec.localId,
            selectedColor: AppColors.textPrimary,
            leading: Icon(Icons.photo_library_outlined, color: AppColors.medBlue),
            title: Text(l.wallpaperPhoto, style: AppText.bodyPrimary),
            trailing: currentId == WallpaperSpec.localId
                ? const Icon(Icons.check, color: AppColors.medBlue)
                : null,
            onTap: _pickPhoto,
          ),
          ListTile(
            key: const ValueKey('wallpaper-none'),
            selected: currentId == null || currentId.isEmpty,
            selectedColor: AppColors.textPrimary,
            leading: Icon(Icons.hide_image_outlined, color: AppColors.medBlue),
            title: Text(l.wallpaperNone, style: AppText.bodyPrimary),
            trailing: currentId == null || currentId.isEmpty
                ? const Icon(Icons.check, color: AppColors.medBlue)
                : null,
            onTap: () => _apply(null),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenHorizontal + AppSpacing.xs,
          AppSpacing.lg,
          AppSpacing.screenHorizontal,
          AppSpacing.sm,
        ),
        child: Semantics(header: true, child: Text(text.toUpperCase(), style: AppText.label)),
      );
}

class _Grid extends StatelessWidget {
  final List<Widget> children;

  /// Tiles carry a name under the swatch: the row grows by two lines of it
  /// at the user's text size, so the swatch keeps its size and the name is
  /// not cut to a few characters.
  final bool labelled;
  const _Grid({required this.children, this.labelled = false});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          const columns = 4;
          final tile = (box.maxWidth -
                  2 * AppSpacing.screenHorizontal -
                  (columns - 1) * AppSpacing.sm) /
              columns;
          // Swatch as before (the tile was 1:1.25 with a one-line name), plus
          // a second line of the 11pt label when there is one.
          final extent = tile / 0.8 +
              (labelled ? MediaQuery.textScalerOf(context).scale(2 * 16) - 16 : 0);
          return GridView(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: AppSpacing.sm,
              crossAxisSpacing: AppSpacing.sm,
              mainAxisExtent: extent,
            ),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenHorizontal),
            children: children,
          );
        },
      );
}

class _Tile extends StatelessWidget {
  final Widget child;
  final bool selected;
  final String? label;

  /// VoiceOver name for a tile with no visible [label] (the solid colours).
  final String? semanticLabel;
  final VoidCallback onTap;
  const _Tile({
    super.key,
    required this.child,
    required this.selected,
    required this.onTap,
    this.label,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        button: true,
        selected: selected,
        label: semanticLabel,
        child: InkWell(
        onTap: onTap,
        borderRadius: AppRadii.rMd,
        child: Column(
          children: [
            Expanded(
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppColors.threadBg,
                  borderRadius: AppRadii.rMd,
                  border: Border.all(
                    color: selected ? AppColors.medBlue : AppColors.border,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    child,
                    if (selected)
                      const Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.check_circle, color: AppColors.medBlue, size: 18),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (label != null) ...[
              const SizedBox(height: 4),
              Text(label!, style: AppText.timestamp, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis),
            ],
          ],
        ),
        ),
      );
}

class _Bubble extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  final BorderRadius radius;
  const _Bubble({required this.text, required this.bg, required this.fg, required this.radius});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: Text(text, style: AppText.messageBody.copyWith(color: fg)),
      );
}
