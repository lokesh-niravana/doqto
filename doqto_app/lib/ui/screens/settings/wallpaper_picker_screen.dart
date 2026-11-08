import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/chat_theme.dart';
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
/// or none, with a live preview on top and a dim slider in dark mode. No
/// [conversationId] = device default; otherwise `prefs.wallpaper` per chat.
class WallpaperPickerScreen extends ConsumerStatefulWidget {
  final String? conversationId;
  const WallpaperPickerScreen({super.key, this.conversationId});

  @override
  ConsumerState<WallpaperPickerScreen> createState() => _WallpaperPickerScreenState();
}

class _WallpaperPickerScreenState extends ConsumerState<WallpaperPickerScreen> {
  final _dimDebounce = SettingDebouncer();
  double? _dimDragging;

  @override
  void dispose() {
    _dimDebounce.dispose();
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
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = ref.watch(appSettingsProvider);
    final dark = AppColors.isDark;
    final convId = widget.conversationId;
    final conv = convId == null
        ? null
        : ref.watch(conversationsProvider).asData?.value.where((c) => c.id == convId).firstOrNull;
    final String? currentId = convId == null ? settings.wallpaper : conv?.prefs.wallpaper;
    final preview = ChatThemeResolver.resolve(
      dark: dark,
      chatTheme: conv?.prefs.theme,
      wallpaper: currentId,
      defaultTheme: settings.chatTheme,
      defaultWallpaper: convId == null ? null : settings.wallpaper,
      dim: _dimDragging ?? settings.wallpaperDim,
      localPhoto: ref.watch(wallpaperPhotoProvider(_photoKey)),
    );
    final ink = preview.patternInk;

    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.wallpaperTitle)),
      body: ListView(
        key: const ValueKey('wallpaper-list'),
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          // Live preview.
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
            child: ClipRRect(
              borderRadius: AppRadii.rLg,
              child: SizedBox(
                key: const ValueKey('wallpaper-preview'),
                height: 180,
                child: ChatWallpaperBackground(
                  data: preview,
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
              ),
            ),
          ),
          if (dark)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenHorizontal),
              child: Row(
                children: [
                  Icon(Icons.brightness_6_outlined, size: 18, color: AppColors.textMuted),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(l.wallpaperDim, style: AppText.caption)),
                  SizedBox(
                    width: 160,
                    child: Slider(
                      key: const ValueKey('wallpaper-dim'),
                      value: _dimDragging ?? settings.wallpaperDim,
                      activeColor: AppColors.medBlue,
                      onChanged: (v) {
                        setState(() => _dimDragging = v);
                        _dimDebounce(() {
                          ref.read(appSettingsProvider.notifier).setWallpaperDim(v);
                          if (mounted) setState(() => _dimDragging = null);
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
          _Header(l.wallpaperPatterns),
          _Grid(
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
                  onTap: () => _apply(WallpaperSpec.solidId(WallpaperSpec.solids[i])),
                  child: ColoredBox(color: WallpaperSpec.solids[i]),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ListTile(
            key: const ValueKey('wallpaper-photo'),
            leading: Icon(Icons.photo_library_outlined, color: AppColors.medBlue),
            title: Text(l.wallpaperPhoto, style: AppText.bodyPrimary),
            trailing: currentId == WallpaperSpec.localId
                ? const Icon(Icons.check, color: AppColors.medBlue)
                : null,
            onTap: _pickPhoto,
          ),
          ListTile(
            key: const ValueKey('wallpaper-none'),
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
        child: Text(text.toUpperCase(), style: AppText.label),
      );
}

class _Grid extends StatelessWidget {
  final List<Widget> children;
  const _Grid({required this.children});
  @override
  Widget build(BuildContext context) => GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenHorizontal),
        mainAxisSpacing: AppSpacing.sm,
        crossAxisSpacing: AppSpacing.sm,
        childAspectRatio: 0.8,
        children: children,
      );
}

class _Tile extends StatelessWidget {
  final Widget child;
  final bool selected;
  final String? label;
  final VoidCallback onTap;
  const _Tile({
    super.key,
    required this.child,
    required this.selected,
    required this.onTap,
    this.label,
  });

  @override
  Widget build(BuildContext context) => InkWell(
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
              Text(label!, style: AppText.timestamp, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ],
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
