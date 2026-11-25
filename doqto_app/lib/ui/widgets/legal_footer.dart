import 'package:flutter/gestures.dart';
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

    return Semantics(
      key: const ValueKey('legal-footer'),
      container: true,
      child: Text.rich(
        TextSpan(
          style: base,
          children: [
            const TextSpan(text: Strings.legalByContinuing),
            TextSpan(
              text: Strings.legalTerms,
              style: link,
              semanticsLabel: Strings.legalTerms,
              recognizer: TapGestureRecognizer()..onTap = () => open(links.terms),
            ),
            const TextSpan(text: Strings.legalAnd),
            TextSpan(
              text: Strings.legalPrivacy,
              style: link,
              recognizer: TapGestureRecognizer()..onTap = () => open(links.privacy),
            ),
            const TextSpan(text: '.'),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
