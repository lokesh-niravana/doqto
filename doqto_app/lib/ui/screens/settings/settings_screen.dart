import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/error_messages.dart';
import '../../../data/services/auth_broker.dart';
import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../l10n/l10n.dart';
import '../../../state/auth_state.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/settings_rows.dart';
import '../../../core/utils/avatar_urls.dart';
import '../../widgets/confirm_sign_out.dart';
import '../../widgets/silent_hint.dart';

/// Settings home (batch 6): a profile card, then grouped entries into the
/// Account, Privacy, Chats & appearance, Notifications, Storage, Language and
/// Help screens. Keys: `settings-<name>` so tests can address each row.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// App Store 5.1.1(v) requires deletion be initiated in-app. Deliberately
  /// high-friction: the exact word must be typed, because this destroys the
  /// profile, all authored messages and the whole connection graph.
  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    if (!await confirmDeleteAccount(context)) return;
    if (!context.mounted) return;
    await deleteAccountAndLeave(context, ref);
  }

  /// Signing out wipes this phone's cached chats and anything still waiting
  /// to send, so it is confirmed first — the same dialog as on Profile.
  Future<void> _confirmAndSignOut(BuildContext context, WidgetRef ref) async {
    if (!await confirmSignOut(context) || !context.mounted) return;
    final busy = _showBusy(context);
    try {
      await ref.read(authProvider.notifier).signOut();
    } finally {
      busy.remove();
    }
    if (context.mounted) context.go(AppRoutes.login);
  }

  /// A dimmed, untappable layer with a spinner while sign-out or deletion
  /// runs. An overlay entry rather than a dialog route: the router replaces
  /// the page underneath when the session ends, and a route pushed on top of
  /// it would be torn down mid-flight.
  static OverlayEntry _showBusy(BuildContext context) {
    final entry = OverlayEntry(
      builder: (_) => const Stack(
        children: [
          ModalBarrier(dismissible: false, color: Color(0x66000000)),
          Center(child: CircularProgressIndicator(semanticsLabel: Strings.loading)),
        ],
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    return entry;
  }

  /// Runs the deletion after the person has confirmed. Shared with the
  /// registration screen, where a half-registered account can be deleted
  /// too. Sign in with Apple accounts confirm with Apple once more so their
  /// tokens can be revoked; backing out of that leaves the account alone.
  static Future<void> deleteAccountAndLeave(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final busy = _showBusy(context);
    final bool deleted;
    try {
      // Also signs out, which wipes the local encrypted PHI caches.
      deleted = await ref.read(authProvider.notifier).deleteAccount();
    } catch (e) {
      busy.remove();
      // A sign-in problem (wrong Apple ID, Apple refused) has its own
      // explanation; "try again" alone would send the person round in circles.
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            e is AuthBrokerException
                ? ErrorMessages.forApi(e)
                : "Couldn't delete your account. Try again.",
          ),
        ),
      );
      return;
    }
    busy.remove();
    if (!deleted) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Your account was not deleted.')),
      );
      return;
    }
    if (context.mounted) context.go(AppRoutes.login);
  }

  /// The type-DELETE confirmation. True only when the person armed and
  /// pressed Delete.
  static Future<bool> confirmDeleteAccount(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const _DeleteAccountDialog(),
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final user = ref.watch(authProvider).user;
    final status = user?.statusLabel();
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: ListView(
        key: const ValueKey('settings-list'),
        // Explicit padding replaces the automatic safe-area inset, so the
        // home-indicator height is added back.
        padding: EdgeInsets.only(
          bottom: AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          // Profile card → edit profile.
          FadeSlideIn.staggered(
            0,
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenHorizontal,
                AppSpacing.sm,
                AppSpacing.screenHorizontal,
                AppSpacing.sm,
              ),
              child: ListTile(
                key: const ValueKey('settings-profile'),
                tileColor: AppColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadii.rLg,
                  side: BorderSide(color: AppColors.border),
                ),
                leading: DoctorAvatar(
                  initials: user?.initials ?? '?',
                  size: AvatarSize.lg,
                  imageUrl: userAvatarUrl(user?.id, user?.avatarUrl),
                ),
                title: Text(user?.fullName ?? '—', style: AppText.heading),
                subtitle: Text(
                  status ?? user?.specialty ?? user?.phone ?? '',
                  key: const ValueKey('settings-profile-subtitle'),
                  style: AppText.caption,
                  // Room for a status at a large text size.
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                onTap: () => context.push(AppRoutes.profileEdit),
              ),
            ),
          ),
          FadeSlideIn.staggered(
            1,
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.screenHorizontal, vertical: AppSpacing.sm),
              child: ListTile(
                key: const ValueKey('settings-invite'),
                tileColor: AppColors.medBlueLight,
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadii.rLg,
                  side: const BorderSide(color: AppColors.medBlue, width: 1.5),
                ),
                leading: const CircleAvatar(
                  backgroundColor: AppColors.medBlue,
                  foregroundColor: AppColors.white,
                  child: Icon(Icons.person_add_alt_1, size: 20),
                ),
                title: const Text(Strings.inviteTitle,
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text(Strings.inviteSettingsSubtitle),
                trailing: const Icon(Icons.chevron_right, color: AppColors.medBlue),
                onTap: () => context.push(AppRoutes.invite),
              ),
            ),
          ),
          FadeSlideIn.staggered(
            2,
            SettingsSection(
              title: l.settingsAccount,
              children: [
                _NavRow(
                  id: 'change-number',
                  icon: Icons.phone_iphone,
                  title: l.settingsChangeNumber,
                  subtitle: user?.phone,
                  route: AppRoutes.changeNumber,
                ),
                _NavRow(
                  id: 'two-step',
                  icon: Icons.password_rounded,
                  title: l.settingsTwoStep,
                  subtitle: (user?.pinEnabled ?? false) ? l.commonOn : l.commonOff,
                  route: AppRoutes.twoStepPin,
                ),
                _NavRow(
                  id: 'devices',
                  icon: Icons.devices_rounded,
                  title: l.settingsLinkedDevices,
                  route: AppRoutes.linkedDevices,
                ),
                _NavRow(
                  id: 'export',
                  icon: Icons.download_rounded,
                  title: l.settingsExport,
                  route: AppRoutes.help,
                  onTap: () => _requestExport(context, ref),
                  last: true,
                ),
              ],
            ),
          ),
          FadeSlideIn.staggered(
            3,
            SettingsSection(
              title: l.settingsPrivacy,
              children: [
                _NavRow(
                  id: 'privacy',
                  icon: Icons.lock_outline,
                  title: l.settingsPrivacy,
                  subtitle: l.settingsPrivacySubtitle,
                  route: AppRoutes.privacy,
                ),
                _NavRow(
                  id: 'app-lock',
                  icon: Icons.fingerprint,
                  title: l.settingsAppLock,
                  route: AppRoutes.appLock,
                  last: true,
                ),
              ],
            ),
          ),
          FadeSlideIn.staggered(
            4,
            SettingsSection(
              title: l.chatsTitle,
              children: [
                _NavRow(
                  id: 'appearance',
                  icon: Icons.palette_outlined,
                  title: l.settingsAppearance,
                  subtitle: l.settingsAppearanceSubtitle,
                  route: AppRoutes.appearance,
                ),
                _NavRow(
                  id: 'notifications',
                  icon: Icons.notifications_none_rounded,
                  title: l.settingsNotifications,
                  subtitle: l.settingsNotificationsSubtitle,
                  route: AppRoutes.notifications,
                ),
                _NavRow(
                  id: 'starred',
                  icon: Icons.star_outline_rounded,
                  title: l.settingsStarred,
                  route: AppRoutes.starred,
                ),
                _NavRow(
                  id: 'storage',
                  icon: Icons.data_usage_rounded,
                  title: l.settingsStorage,
                  subtitle: l.settingsStorageSubtitle,
                  route: AppRoutes.storage,
                  last: true,
                ),
              ],
            ),
          ),
          FadeSlideIn.staggered(
            5,
            SettingsSection(
              title: l.settingsHelp,
              children: [
                _NavRow(
                  id: 'language',
                  icon: Icons.language_rounded,
                  title: l.settingsLanguage,
                  subtitle: _languageLabel(context, ref),
                  route: AppRoutes.language,
                ),
                _NavRow(
                  id: 'help',
                  icon: Icons.help_outline_rounded,
                  title: l.settingsHelp,
                  subtitle: l.settingsHelpSubtitle,
                  route: AppRoutes.help,
                  last: true,
                ),
              ],
            ),
          ),
          FadeSlideIn.staggered(
            6,
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: AppButton(
                key: const ValueKey('settings-sign-out'),
                label: l.settingsSignOut,
                icon: Icons.logout,
                variant: AppButtonVariant.danger,
                expand: true,
                onPressed: () => _confirmAndSignOut(context, ref),
              ),
            ),
          ),
          FadeSlideIn.staggered(
            7,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg)
                  .copyWith(bottom: AppSpacing.lg),
              child: TextButton(
                key: const ValueKey('settings-delete-account'),
                onPressed: () => _confirmAndDelete(context, ref),
                child: Text(
                  l.settingsDeleteAccount,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _languageLabel(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final code = Localizations.localeOf(context).languageCode;
    return code == 'es' ? l.languageSpanish : l.languageEnglish;
  }

  /// Account info export: a 10-minute presigned JSON. Opened through the
  /// system share sheet / browser so nothing is cached in-app.
  Future<void> _requestExport(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.settingsExport),
        // Scrolls rather than clipping at a large text size.
        scrollable: true,
        content: const Text(
          'We\'ll prepare a file with your profile, settings, organizations, '
          'connections and groups. It never includes messages. The link works '
          'for 10 minutes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.commonCancel),
          ),
          TextButton(
            key: const ValueKey('export-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Request'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    try {
      final r = await ref.read(settingsRepositoryProvider).requestExport();
      // open() reports a link the system could not hand off; say so rather
      // than leave the user waiting for a file that never appears.
      final opened = await ref.read(urlOpenerProvider).open(r.url);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(Strings.exportOpenFailed)),
        );
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(Strings.exportRequestFailed)),
      );
    }
  }
}

class _NavRow extends StatelessWidget {
  final String id;
  final IconData icon;
  final String title;
  final String? subtitle;
  final String route;
  final VoidCallback? onTap;
  final bool last;
  const _NavRow({
    required this.id,
    required this.icon,
    required this.title,
    required this.route,
    this.subtitle,
    this.onTap,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          key: ValueKey('settings-$id'),
          leading: Icon(icon, color: AppColors.medBlue),
          title: Text(title, style: AppText.bodyPrimary),
          subtitle: subtitle == null || subtitle!.isEmpty
              ? null
              // Not one line: Spanish and large text sizes were cut off.
              : Text(subtitle!, style: AppText.caption, maxLines: 3, overflow: TextOverflow.ellipsis),
          trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
          onTap: onTap ?? () => context.push(route),
        ),
        if (!last) const Divider(height: 1, indent: AppSpacing.lg),
      ],
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final armed = _controller.text.trim() == 'DELETE';
    return AlertDialog(
      title: const Text('Delete account'),
      // Scrolls so the field stays reachable with the keyboard up at a large
      // text size.
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This permanently deletes your profile, your messages and your '
            'connections. It cannot be undone.\n\nType DELETE to confirm.',
          ),
          const SizedBox(height: AppSpacing.md),
          Semantics(
            label: Strings.a11yDeleteConfirmField,
            child: TextField(
              controller: _controller,
              autocorrect: false,
              // The word to type is upper case; start the keyboard that way.
              textCapitalization: TextCapitalization.characters,
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
              decoration: const InputDecoration(hint: SilentHint('DELETE')),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: armed ? () => Navigator.of(context).pop(true) : null,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
