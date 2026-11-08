import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/models/app_meta.dart';
import '../../../l10n/l10n.dart';
import '../../../state/app_meta_state.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/settings_rows.dart';

/// Settings → Help (batch 6): support and legal links from `GET /app/legal`
/// (defaults while loading / offline), open-source licences, version.
class HelpScreen extends ConsumerWidget {
  const HelpScreen({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref, String url) async {
    final ok = await ref.read(urlOpenerProvider).open(url);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.helpOpenFailed)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final links = ref.watch(legalLinksProvider).asData?.value ?? LegalLinks.defaults;
    final version = ref.watch(appVersionProvider).asData?.value;

    Widget row(String name, IconData icon, String title, String url, {bool last = false}) {
      return Column(
        children: [
          ListTile(
            key: ValueKey('help-$name'),
            leading: Icon(icon, color: AppColors.medBlue),
            title: Text(title, style: AppText.bodyPrimary),
            trailing: Icon(Icons.open_in_new_rounded, size: 18, color: AppColors.gray600),
            onTap: () => _open(context, ref, url),
          ),
          if (!last) const Divider(height: 1, indent: AppSpacing.xxxl + AppSpacing.lg),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.settingsHelp)),
      body: ListView(
        key: const ValueKey('help-list'),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        children: [
          FadeSlideIn.staggered(
            0,
            SettingsSection(
              title: l.helpSupportSection,
              children: [
                row('centre', Icons.help_outline_rounded, l.helpCentre, links.help),
                row('contact', Icons.mail_outline_rounded, l.helpContact, links.contact, last: true),
              ],
            ),
          ),
          FadeSlideIn.staggered(
            1,
            SettingsSection(
              title: l.helpLegalSection,
              children: [
                row('terms', Icons.description_outlined, l.helpTerms, links.terms),
                row('privacy', Icons.privacy_tip_outlined, l.helpPrivacy, links.privacy),
                row('hipaa', Icons.health_and_safety_outlined, l.helpHipaa, links.hipaa),
                ListTile(
                  key: const ValueKey('help-licences'),
                  leading: Icon(Icons.article_outlined, color: AppColors.medBlue),
                  title: Text(l.helpLicences, style: AppText.bodyPrimary),
                  trailing: Icon(Icons.chevron_right_rounded, color: AppColors.gray600),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'Doqto',
                    applicationVersion: version,
                  ),
                ),
              ],
            ),
          ),
          if (version != null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Text(
                l.settingsVersion(version),
                key: const ValueKey('help-version'),
                style: AppText.caption,
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}
