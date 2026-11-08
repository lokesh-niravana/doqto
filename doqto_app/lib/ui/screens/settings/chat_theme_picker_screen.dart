import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/chat_theme.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/conversation_prefs.dart';
import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/settings_state.dart';

/// Chat colour picker (batch 6). With no [conversationId] it sets the device
/// default ([appSettingsProvider]); with one it writes `prefs.theme` for that
/// chat through the optimistic `setPrefs` (rolled back with a toast if the
/// server refuses). The first tile is "Default" = null.
class ChatThemePickerScreen extends ConsumerWidget {
  final String? conversationId;
  const ChatThemePickerScreen({super.key, this.conversationId});

  Future<void> _pick(BuildContext context, WidgetRef ref, String? id) async {
    final convId = conversationId;
    if (convId == null) {
      await ref.read(appSettingsProvider.notifier).setChatTheme(id);
      return;
    }
    final notifier = ref.read(conversationsProvider.notifier);
    final prefs = notifier.conversation(convId)?.prefs ?? ConversationPrefs.defaults;
    try {
      await notifier.setPrefs(
        convId,
        optimistic: prefs.copyWith(theme: () => id),
        patch: {'theme': id},
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessages.forApi(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final dark = AppColors.isDark;
    final settings = ref.watch(appSettingsProvider);
    final convId = conversationId;
    final String? current = convId == null
        ? settings.chatTheme
        : ref
            .watch(conversationsProvider)
            .asData
            ?.value
            .where((c) => c.id == convId)
            .firstOrNull
            ?.prefs
            .theme;
    // What "Default" resolves to right now (device default, else teal).
    final fallback = convId == null
        ? ChatTheme.teal
        : (ChatTheme.byId(settings.chatTheme) ?? ChatTheme.teal);

    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.chatThemeTitle)),
      body: GridView.count(
        key: const ValueKey('chat-theme-grid'),
        crossAxisCount: 2,
        padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        childAspectRatio: 1.15,
        children: [
          _ThemeTile(
            key: const ValueKey('chat-theme-default'),
            theme: fallback,
            dark: dark,
            name: l.chatThemeDefault,
            subtitle: convId == null ? fallback.name : l.chatThemeDefaultHint,
            selected: current == null,
            onTap: () => _pick(context, ref, null),
          ),
          for (final t in ChatTheme.all)
            _ThemeTile(
              key: ValueKey('chat-theme-${t.id}'),
              theme: t,
              dark: dark,
              name: t.name,
              selected: current == t.id,
              onTap: () => _pick(context, ref, t.id),
            ),
        ],
      ),
    );
  }
}

/// A card with a two-bubble preview of the theme in the current brightness.
class _ThemeTile extends StatelessWidget {
  final ChatTheme theme;
  final bool dark;
  final String name;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeTile({
    super.key,
    required this.theme,
    required this.dark,
    required this.name,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Material(
      color: AppColors.surface,
      borderRadius: AppRadii.rLg,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadii.rLg,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: AppRadii.rLg,
            border: Border.all(
              color: selected ? AppColors.medBlue : AppColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.threadBg,
                    borderRadius: AppRadii.rMd,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _MiniBubble(
                          text: l.chatThemeReceived,
                          bg: theme.received(dark),
                          fg: AppColors.textPrimary,
                          radius: AppRadii.bubbleReceived,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _MiniBubble(
                          text: l.chatThemeSent,
                          bg: theme.sent(dark),
                          fg: theme.onSent(dark),
                          radius: AppRadii.bubbleSent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: AppText.subheading, maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (subtitle != null)
                          Text(subtitle!, style: AppText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  if (selected)
                    const Icon(Icons.check_circle, color: AppColors.medBlue, size: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniBubble extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  final BorderRadius radius;
  const _MiniBubble({
    required this.text,
    required this.bg,
    required this.fg,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(maxWidth: 110),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.timestamp.copyWith(color: fg),
        ),
      );
}
