import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/motion.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/typography.dart';
import '../../../state/chat_state.dart';
import '../../../state/network_state.dart';
import '../../widgets/app_pressable.dart';

/// Total unread across all conversations — drives the badge on the Chats tab.
/// Derived read-only from the existing conversations provider.
final _totalUnreadProvider = Provider<int>((ref) {
  final convs = ref.watch(conversationsProvider).asData?.value;
  if (convs == null) return 0;
  return convs.fold<int>(0, (sum, c) => sum + c.unreadCount);
});

/// Pending received-invitation count — drives the badge on the Network tab.
final _pendingInvitesProvider = Provider<int>((ref) {
  return ref.watch(invitationsProvider).asData?.value.length ?? 0;
});

/// One nav-bar entry, bound to a shell branch index.
class _NavSpec {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int branch;
  const _NavSpec(this.icon, this.activeIcon, this.label, this.branch);
}

const List<_NavSpec> _navSpecs = [
  _NavSpec(Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded,
      Strings.tabChats, 0),
  _NavSpec(Icons.people_alt_outlined, Icons.people_alt_rounded,
      Strings.netTabNetwork, 1),
  _NavSpec(Icons.groups_outlined, Icons.groups_rounded, Strings.netTabGroups, 2),
  _NavSpec(Icons.apartment_outlined, Icons.apartment_rounded, Strings.tabMyOrg,
      3),
];

/// App shell: content runs edge-to-edge behind a floating frosted-glass nav
/// bar (2025 chrome — no solid slabs, no notched FAB cutout). The mic action
/// is a raised gradient button overlapping the bar. Four branches
/// ([Chats] [Network] (mic) [Groups] [My Org]) render via an IndexedStack, so
/// each tab keeps its own navigation state.
class MainShell extends StatelessWidget {
  final StatefulNavigationShell navigationShell;
  const MainShell({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true, // content scrolls behind the translucent bar
      body: navigationShell,
      floatingActionButton: _MicButton(
        onPressed: () => context.push(AppRoutes.record),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: _FrostedNavBar(navigationShell: navigationShell),
    );
  }
}

/// Raised broadcast button: brand teal→navy gradient, floats over the bar.
class _MicButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _MicButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return AppPressable(
      onTap: onPressed,
      haptic: true,
      child: Container(
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.medBlue, AppColors.medBlueDark],
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.medBlueDark.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: const Icon(Icons.mic_rounded, color: AppColors.white, size: 26),
      ),
    );
  }
}

class _FrostedNavBar extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;
  const _FrostedNavBar({required this.navigationShell});

  void _go(int branch) {
    // initialLocation:true resets a re-tapped tab to its root; a hop to a new
    // tab restores that branch's saved stack.
    navigationShell.goBranch(
      branch,
      initialLocation: branch == navigationShell.currentIndex,
    );
  }

  int _badgeFor(int branch, int unread, int invites) => switch (branch) {
        0 => unread,
        1 => invites,
        _ => 0,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(_totalUnreadProvider);
    final invites = ref.watch(_pendingInvitesProvider);
    final current = navigationShell.currentIndex;

    // Items 0–1 sit left of the mic gap, 2–3 to its right.
    final left = _navSpecs.where((s) => s.branch < 2);
    final right = _navSpecs.where((s) => s.branch >= 2);

    Widget item(_NavSpec s) => Expanded(
          child: _NavItem(
            icon: s.icon,
            activeIcon: s.activeIcon,
            label: s.label,
            isSelected: current == s.branch,
            badgeCount: _badgeFor(s.branch, unread, invites),
            onTap: () => _go(s.branch),
          ),
        );

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.white.withValues(alpha: 0.82),
            border: Border(
              top: BorderSide(
                color: AppColors.gray200.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 64,
              child: Row(
                children: [
                  for (final s in left) item(s),
                  const SizedBox(width: 64), // clearance for the mic button
                  for (final s in right) item(s),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isSelected;
  final int badgeCount;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppColors.medBlue : AppColors.gray400;
    final duration = AppMotion.maybe(context, AppMotion.micro);
    return AppPressable(
      onTap: onTap,
      minTarget: true,
      child: Center(
        // Active pill: tint + label weight animate in place (never shifts
        // layout) so the current tab is unmistakable.
        child: AnimatedContainer(
          duration: duration,
          curve: AppMotion.standard,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.medBlueLight : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(isSelected ? activeIcon : icon, color: color, size: 23),
                  // Badge — overlays the icon corner so it never shifts
                  // layout; scales in/out as the count crosses zero.
                  Positioned(
                    top: -5,
                    right: -10,
                    child: AnimatedScale(
                      scale: badgeCount > 0 ? 1.0 : 0.0,
                      duration: duration,
                      curve: AppMotion.standard,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        constraints: const BoxConstraints(minWidth: 16),
                        decoration: BoxDecoration(
                          color: AppColors.medBlue,
                          borderRadius: AppRadii.rFull,
                          border:
                              Border.all(color: AppColors.white, width: 1.5),
                        ),
                        child: Text(
                          badgeCount > 99 ? '99+' : '$badgeCount',
                          textAlign: TextAlign.center,
                          style: AppText.badge
                              .copyWith(color: AppColors.white, fontSize: 9),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // FittedBox is the 320dp safety valve — the label scales down
              // rather than overflowing when four tabs share a narrow bar.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: AppText.button.copyWith(
                    fontSize: 10,
                    color: color,
                    fontWeight:
                        isSelected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
