import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/chat_theme.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/settings_state.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/settings_rows.dart';

/// Settings → Chats & appearance (batch 6). Display theme, font size, the
/// device-wide chat colour / wallpaper defaults, Enter-is-send, voice
/// transcript and keep-chats-archived. Every row writes through
/// [appSettingsProvider] at once; nothing here talks to the server.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final s = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final dark = AppColors.isDark;
    final defaultTheme = ChatTheme.byId(s.chatTheme) ?? ChatTheme.teal;
    final wallpaper = WallpaperSpec.parse(s.wallpaper);
    final wallpaperLabel = s.wallpaper == WallpaperSpec.localId
        ? l.appearanceWallpaperPhoto
        : wallpaper.pattern?.label ??
            (wallpaper.solid != null ? l.wallpaperSolids : l.appearanceWallpaperNone);

    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.appearanceTitle)),
      body: ListView(
        key: const ValueKey('appearance-list'),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        children: [
          FadeSlideIn.staggered(
            0,
            SettingsSection(
              title: l.appearanceDisplay,
              footer: l.appearanceFontHint,
              children: [
                SettingsChoiceRow<ThemeMode>(
                  keyPrefix: 'appearance',
                  field: 'theme',
                  title: l.appearanceTheme,
                  value: s.themeMode,
                  options: [
                    (ThemeMode.light, l.appearanceThemeLight),
                    (ThemeMode.dark, l.appearanceThemeDark),
                    (ThemeMode.system, l.appearanceThemeSystem),
                  ],
                  wire: AppSettings.modeWire,
                  onPick: notifier.setThemeMode,
                ),
                SettingsChoiceRow<AppFontSize>(
                  keyPrefix: 'appearance',
                  field: 'font_size',
                  title: l.appearanceFontSize,
                  value: s.fontSize,
                  options: [
                    (AppFontSize.small, l.appearanceFontSmall),
                    (AppFontSize.medium, l.appearanceFontMedium),
                    (AppFontSize.large, l.appearanceFontLarge),
                  ],
                  wire: (v) => v.wire,
                  onPick: notifier.setFontSize,
                ),
                // Live preview of the chosen size, in the message style.
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm + 2,
                      ),
                      decoration: BoxDecoration(
                        color: defaultTheme.sent(dark),
                        borderRadius: AppRadii.bubbleSent,
                      ),
                      child: Text(
                        l.appearancePreview,
                        key: const ValueKey('appearance-preview'),
                        style: AppText.messageBody.copyWith(
                          color: defaultTheme.onSent(dark),
                          fontSize: AppText.messageBody.fontSize! * s.fontSize.factor,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          FadeSlideIn.staggered(
            1,
            SettingsSection(
              title: l.appearanceChatsSection,
              children: [
                ListTile(
                  key: const ValueKey('appearance-row-chat_theme'),
                  leading: _Swatch(color: defaultTheme.sent(dark)),
                  title: Text(l.appearanceDefaultChatTheme, style: AppText.bodyPrimary),
                  subtitle: Text(
                    defaultTheme.name,
                    key: const ValueKey('appearance-value-chat_theme'),
                    style: AppText.caption.copyWith(color: AppColors.medBlue),
                  ),
                  trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                  onTap: () => context.push(AppRoutes.chatThemeDefault),
                ),
                const Divider(height: 1, indent: AppSpacing.lg),
                ListTile(
                  key: const ValueKey('appearance-row-wallpaper'),
                  leading: Icon(Icons.wallpaper_rounded, color: AppColors.medBlue),
                  title: Text(l.appearanceDefaultWallpaper, style: AppText.bodyPrimary),
                  subtitle: Text(
                    wallpaperLabel,
                    key: const ValueKey('appearance-value-wallpaper'),
                    style: AppText.caption.copyWith(color: AppColors.medBlue),
                  ),
                  trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                  onTap: () => context.push(AppRoutes.wallpaperDefault),
                ),
                const Divider(height: 1, indent: AppSpacing.lg),
                SettingsSwitchRow(
                  keyPrefix: 'appearance',
                  field: 'enter_is_send',
                  title: l.appearanceEnterIsSend,
                  subtitle: l.appearanceEnterIsSendHint,
                  value: s.enterIsSend,
                  onChanged: notifier.setEnterIsSend,
                ),
                SettingsSwitchRow(
                  keyPrefix: 'appearance',
                  field: 'voice_transcript',
                  title: l.appearanceVoiceTranscript,
                  subtitle: l.appearanceVoiceTranscriptHint,
                  value: s.voiceTranscript,
                  onChanged: notifier.setVoiceTranscript,
                ),
                SettingsSwitchRow(
                  keyPrefix: 'settings',
                  field: 'keep_archived',
                  title: l.appearanceKeepArchived,
                  subtitle: l.appearanceKeepArchivedHint,
                  value: ref.watch(keepArchivedProvider),
                  onChanged: (v) => ref.read(keepArchivedProvider.notifier).set(v),
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  const _Swatch({required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.border),
        ),
      );
}
