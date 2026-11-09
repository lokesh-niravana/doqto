import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/organization.dart';
import '../../../data/models/user.dart';
import '../../../state/auth_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';
import '../../../core/utils/avatar_urls.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  /// When null, the screen shows the signed-in user in editable mode.
  /// When non-null, the screen renders that org member in read-only "view"
  /// mode — name/specialty/avatar only (the API exposes no phone/email/NPI
  /// for other members, per HIPAA minimum-necessary).
  final OrgMember? member;

  const ProfileScreen({super.key, this.member});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _refreshing = false;
  bool _signingOut = false;

  bool get _isSelf => widget.member == null;

  @override
  void initState() {
    super.initState();
    if (_isSelf) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final me = await ref.read(authRepositoryProvider).me();
      ref.read(authProvider.notifier).setUser(me);
    } catch (_) {
      // silent — the existing cached user stays visible.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _confirmAndSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          "You'll need to verify your phone to sign back in.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _signingOut = true);
    try {
      await ref.read(authProvider.notifier).signOut();
      if (!mounted) return;
      context.go(AppRoutes.login);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ),
      );
      setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isSelf) return _MemberProfileView(member: widget.member!);
    final user = ref.watch(authProvider).user;
    if (user == null) {
      return const Scaffold(body: _ProfileSkeleton());
    }
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(
        title: Text(_isSelf ? 'Profile' : 'Doctor'),
        actions: [
          if (_isSelf)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit profile',
              onPressed: () => context.push(AppRoutes.profileEdit),
            ),
          // The /settings route existed but nothing linked to it, which left
          // account deletion unreachable — App Store 5.1.1(v) requires a user
          // (and a reviewer) to find it in-app.
          if (_isSelf)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: () => context.push(AppRoutes.settings),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _isSelf ? _refresh : () async {},
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
          children: [
            FadeSlideIn.staggered(0, _Header(user: user)),
            const SizedBox(height: AppSpacing.xl),
            FadeSlideIn.staggered(
                1,
                _Section(
                  title: 'About',
                  child: user.bio == null || user.bio!.trim().isEmpty
                      ? _Empty(
                          text: _isSelf
                              ? 'Tap edit to add a short bio.'
                              : 'No bio yet.')
                      : Text(user.bio!, style: AppText.bodyPrimary),
                )),
            FadeSlideIn.staggered(
                2,
                _Section(
                  title: 'Practice',
                  children: [
                    _Row(
                        icon: Icons.badge_outlined,
                        label: 'NPI',
                        value: user.npiNumber),
                    if (user.specialty != null && user.specialty!.isNotEmpty)
                      _Row(
                          icon: Icons.medical_services_outlined,
                          label: 'Specialty',
                          value: user.specialty!),
                    if (user.yearsOfExperience != null)
                      _Row(
                        icon: Icons.timeline,
                        label: 'Experience',
                        value:
                            '${user.yearsOfExperience} year${user.yearsOfExperience == 1 ? '' : 's'}',
                      ),
                  ],
                )),
            FadeSlideIn.staggered(
                3,
                _Section(
                  title: 'Contact',
                  children: [
                    _Row(
                        icon: Icons.phone_outlined,
                        label: 'Phone',
                        value: user.phone),
                    if (user.email != null && user.email!.isNotEmpty)
                      _Row(
                          icon: Icons.alternate_email,
                          label: 'Email',
                          value: user.email!),
                    if (user.locationLabel != null)
                      _Row(
                          icon: Icons.location_on_outlined,
                          label: 'Location',
                          value: user.locationLabel!),
                  ],
                )),
            FadeSlideIn.staggered(
                4,
                _Section(
                  title: 'Skills',
                  child: user.skills.isEmpty
                      ? _Empty(text: 'No skills added yet.')
                      : Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: [
                            for (final s in user.skills) _SkillTag(label: s),
                          ],
                        ),
                )),
            if (_isSelf) ...[
              const SizedBox(height: AppSpacing.lg),
              FadeSlideIn.staggered(
                5,
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screenHorizontal),
                  child: AppButton(
                    label: 'Sign out',
                    variant: AppButtonVariant.danger,
                    icon: Icons.logout,
                    expand: true,
                    loading: _signingOut,
                    onPressed: _signingOut ? null : _confirmAndSignOut,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
            ],
          ],
        ),
      ),
    );
  }
}

class _MemberProfileView extends StatelessWidget {
  final OrgMember member;
  const _MemberProfileView({required this.member});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text('Doctor')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        children: [
          Column(
            children: [
              // Hero pairs with the org member list row (member-avatar-<id>).
              DoctorAvatar(
                initials: member.initials,
                size: AvatarSize.xxl,
                imageUrl: userAvatarUrl(member.id, member.avatarUrl),
                heroTag: 'member-avatar-${member.id}',
              ),
              const SizedBox(height: AppSpacing.md),
              FadeSlideIn.staggered(
                0,
                Text(member.fullName,
                    style: AppText.display, textAlign: TextAlign.center),
              ),
              if (member.specialty case final specialty?
                  when specialty.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                FadeSlideIn.staggered(
                  1,
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.xs + 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.medBlueLight,
                      borderRadius: AppRadii.rFull,
                    ),
                    child: Text(
                      specialty,
                      style: AppText.caption.copyWith(
                        color: AppColors.medBlueDark,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Profile-shaped loading placeholder: avatar circle + name line + section
/// blocks. Replaces the bare spinner while the cached user hydrates.
class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenHorizontal,
        vertical: AppSpacing.xl,
      ),
      children: [
        Center(child: AppSkeleton.circle(size: 104)),
        const SizedBox(height: AppSpacing.md),
        Center(child: AppSkeleton.line(width: 160, height: 16)),
        const SizedBox(height: AppSpacing.sm),
        Center(child: AppSkeleton.line(width: 96)),
        const SizedBox(height: AppSpacing.xl),
        AppSkeleton.block(height: 88),
        const SizedBox(height: AppSpacing.lg),
        AppSkeleton.block(height: 120),
        const SizedBox(height: AppSpacing.lg),
        AppSkeleton.block(height: 120),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final User user;
  const _Header({required this.user});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        DoctorAvatar(
          initials: user.initials,
          size: AvatarSize.xxl,
          imageUrl: userAvatarUrl(user.id, user.avatarUrl),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(user.fullName, style: AppText.display, textAlign: TextAlign.center),
        if (user.statusLabel() case final status?) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(status, key: const ValueKey('profile-status'),
              style: AppText.body, textAlign: TextAlign.center),
        ],
        if (user.specialty != null && user.specialty!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs + 2,
            ),
            decoration: BoxDecoration(
              color: AppColors.medBlueLight,
              borderRadius: AppRadii.rFull,
            ),
            child: Text(
              user.specialty!,
              style: AppText.caption.copyWith(
                color: AppColors.medBlueDark,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        if (user.locationLabel != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.location_on_outlined, size: 14, color: AppColors.textMuted),
              const SizedBox(width: AppSpacing.xs),
              Text(user.locationLabel!, style: AppText.caption),
            ],
          ),
        ],
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget? child;
  final List<Widget>? children;
  const _Section({required this.title, this.child, this.children})
      : assert(child != null || children != null);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenHorizontal,
        AppSpacing.sm,
        AppSpacing.screenHorizontal,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.sm),
            child: Text(title.toUpperCase(), style: AppText.label),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadii.rLg,
              border: Border.all(color: AppColors.border),
            ),
            child: child ??
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _separate(children!),
                ),
          ),
        ],
      ),
    );
  }

  List<Widget> _separate(List<Widget> items) {
    if (items.isEmpty) {
      return [Text('—', style: AppText.caption)];
    }
    final out = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      out.add(items[i]);
      if (i < items.length - 1) {
        out.add(const SizedBox(height: AppSpacing.md));
      }
    }
    return out;
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _Row({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.textMuted),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppText.caption),
              const SizedBox(height: 2),
              Text(value, style: AppText.bodyPrimary),
            ],
          ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(text, style: AppText.caption);
  }
}

class _SkillTag extends StatelessWidget {
  final String label;
  const _SkillTag({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.medBlueLight,
        borderRadius: AppRadii.rFull,
      ),
      child: Text(
        label,
        style: AppText.caption.copyWith(
          color: AppColors.medBlueDark,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
