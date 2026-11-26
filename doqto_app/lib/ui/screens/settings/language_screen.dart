import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../l10n/l10n.dart';
import '../../../state/settings_state.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/settings_rows.dart';

/// Settings → App language (batch 6): system default, English, Español.
class LanguageScreen extends ConsumerWidget {
  const LanguageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final current = ref.watch(appSettingsProvider).locale?.languageCode;
    final options = <(String, String?, String)>[
      ('system', null, l.languageSystem),
      ('en', 'en', l.languageEnglish),
      ('es', 'es', l.languageSpanish),
    ];
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.settingsLanguage)),
      body: ListView(
        key: const ValueKey('language-list'),
        // Explicit padding drops the automatic safe-area inset; add it back so
        // the last row clears the home indicator.
        padding: EdgeInsets.only(
          top: AppSpacing.lg,
          bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          FadeSlideIn.staggered(
            0,
            SettingsSection(
              title: l.settingsLanguage,
              footer: l.languageFooter,
              children: [
                for (var i = 0; i < options.length; i++)
                  Column(
                    children: [
                      ListTile(
                        key: ValueKey('language-opt-${options[i].$1}'),
                        // The tick alone is silent to VoiceOver.
                        selected: current == options[i].$2,
                        selectedColor: AppColors.textPrimary,
                        title: Text(options[i].$3, style: AppText.bodyPrimary),
                        trailing: current == options[i].$2
                            ? Icon(Icons.check_rounded, color: AppColors.medBlue)
                            : null,
                        onTap: () {
                          final code = options[i].$2;
                          ref
                              .read(appSettingsProvider.notifier)
                              .setLocale(code == null ? null : Locale(code));
                        },
                      ),
                      if (i < options.length - 1)
                        const Divider(height: 1, indent: AppSpacing.lg),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
