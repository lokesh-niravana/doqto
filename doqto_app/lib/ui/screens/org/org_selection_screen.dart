import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../state/auth_state.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/section_card.dart';
import '../../widgets/confirm_sign_out.dart';

class OrgSelectionScreen extends ConsumerWidget {
  const OrgSelectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text(Strings.orgSelectTitle)),
      // Scrolls when a large text size leaves too little room.
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.screenHorizontal).copyWith(
          bottom: AppSpacing.screenHorizontal +
              MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.lg),
            FadeSlideIn.staggered(
              0,
              _OrgCard(
                icon: Icons.apartment_rounded,
                title: Strings.orgCreateTitle,
                subtitle: Strings.orgCreateSub,
                onTap: () => context.push(AppRoutes.createOrg),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FadeSlideIn.staggered(
              1,
              _OrgCard(
                icon: Icons.vpn_key_rounded,
                title: Strings.orgJoinTitle,
                subtitle: Strings.orgJoinSub,
                onTap: () => context.push(AppRoutes.joinOrg),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            // Never a dead end: someone who wants neither can leave.
            TextButton(
              key: const ValueKey('org-selection-sign-out'),
              onPressed: () async {
                final auth = ref.read(authProvider.notifier);
                if (!await confirmSignOut(context)) return;
                await auth.signOut();
              },
              style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
              child: const Text(Strings.regSignOut),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrgCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _OrgCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // AppPressable gives the premium scale/opacity press feedback instead of
    // the default InkWell ripple.
    return AppPressable(
      onTap: onTap,
      haptic: true,
      minTarget: true,
      child: SectionCard(
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                  color: AppColors.medBlueLight, shape: BoxShape.circle),
              child: Icon(icon, color: AppColors.medBlueDark),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppText.heading),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppText.caption),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.gray400),
          ],
        ),
      ),
    );
  }
}
