import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/strings.dart';
import '../../core/di/providers.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/typography.dart';
import '../../data/models/app_meta.dart';
import '../../state/app_meta_state.dart';

/// "By continuing you agree to the Terms of Service and Privacy Policy", with
/// both documents one tap away. Shown wherever an account is created or
/// signed in (App Store guideline 1.2 / 5.1.1: users must be able to see and
/// agree to the terms before handing over data). Links come from
/// `GET /app/legal` with the built-in defaults while that loads.
class LegalFooter extends ConsumerWidget {
  const LegalFooter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = ref.watch(legalLinksProvider).asData?.value ?? LegalLinks.defaults;
    final base = AppText.caption.copyWith(color: AppColors.gray600);
    final link = base.copyWith(
      color: AppColors.medBlue,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.medBlue,
    );

    Future<void> open(String url) async {
      final ok = await ref.read(urlOpenerProvider).open(url);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(Strings.legalOpenFailed)),
        );
      }
    }

    // Each link is a real button with a 44pt touch area: a tap recogniser on
    // a 12pt span is only as tall as its line of text (15.6pt).
    Widget linkButton(String label, String url) => TextButton(
          key: ValueKey('legal-link-$label'),
          onPressed: () => open(url),
          style: TextButton.styleFrom(
            minimumSize: const Size(44, 44),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: AppColors.medBlue,
            textStyle: link,
          ),
          child: Text(label, style: link),
        );

    return Semantics(
      key: const ValueKey('legal-footer'),
      container: true,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text(Strings.legalByContinuing.trim(), style: base),
          linkButton(Strings.legalTerms, links.terms),
          Text(Strings.legalAnd.trim(), style: base),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              linkButton(Strings.legalPrivacy, links.privacy),
              Text('.', style: base),
            ],
          ),
        ],
      ),
    );
  }
}
