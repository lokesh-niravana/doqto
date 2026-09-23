import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/billing.dart';
import '../../../state/auth_state.dart';
import '../../../state/billing_state.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// App Store 5.1.1(v) requires deletion be initiated in-app. Deliberately
  /// high-friction: the exact word must be typed, because this destroys the
  /// profile, all authored messages and the whole connection graph.
  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const _DeleteAccountDialog(),
    );
    if (confirmed != true) return;

    try {
      await ref.read(userRepositoryProvider).deleteAccount();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't delete your account. Try again.")),
        );
      }
      return;
    }
    // signOut also wipes the local encrypted PHI caches.
    await ref.read(authProvider.notifier).signOut();
    if (context.mounted) context.go(AppRoutes.login);
  }

  /// Someone with no Stripe customer yet (still on the trial) goes to
  /// checkout; the portal would 409 for them.
  Future<void> _openBilling(
      BuildContext context, WidgetRef ref, Billing? billing) async {
    final repo = ref.read(billingRepositoryProvider);
    String? error;
    try {
      final url = billing?.status == null
          ? await repo.checkoutUrl('yearly')
          : await repo.portalUrl();
      if (!await ref.read(urlOpenerProvider).open(url)) {
        error = Strings.checkoutOpenFailed;
      }
    } catch (e) {
      error = ErrorMessages.forApi(e);
    }
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          FadeSlideIn.staggered(
            0,
            ListTile(
                title: const Text('Name'),
                subtitle: Text(user?.fullName ?? '—')),
          ),
          FadeSlideIn.staggered(
            1,
            ListTile(
                title: const Text('Phone'), subtitle: Text(user?.phone ?? '—')),
          ),
          FadeSlideIn.staggered(
            2,
            ListTile(
                title: const Text('NPI'),
                subtitle: Text(user?.npiNumber ?? '—')),
          ),
          FadeSlideIn.staggered(
            3,
            ListTile(
                title: const Text('Specialty'),
                subtitle: Text(user?.specialty ?? '—')),
          ),
          FadeSlideIn.staggered(
            4,
            Consumer(builder: (context, ref, _) {
              final billing = ref.watch(billingProvider).value;
              // Staff never pay: there is nothing to open for them.
              final staff = billing?.reason == 'staff';
              return ListTile(
                title: const Text(Strings.subscriptionRow),
                subtitle: Text(switch (billing?.reason) {
                  'trial' => Strings.trialDaysLeft(billing!.trialDaysLeft),
                  'subscribed' => billing!.plan == 'yearly'
                      ? Strings.planYearly
                      : Strings.planMonthly,
                  'grace' => Strings.subscriptionGrace,
                  'staff' => Strings.subscriptionStaff,
                  'expired' => Strings.subscriptionNone,
                  _ => '—',
                }),
                trailing:
                    staff ? null : const Icon(Icons.open_in_new, size: 18),
                onTap: staff ? null : () => _openBilling(context, ref, billing),
              );
            }),
          ),
          // Destructive zone: visually separated from the info rows above,
          // rendered in red via the danger variant.
          const SizedBox(height: AppSpacing.sm),
          const Divider(),
          FadeSlideIn.staggered(
            5,
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: AppButton(
                label: 'Sign out',
                icon: Icons.logout,
                variant: AppButtonVariant.danger,
                expand: true,
                onPressed: () async {
                  await ref.read(authProvider.notifier).signOut();
                  if (context.mounted) context.go(AppRoutes.login);
                },
              ),
            ),
          ),
          FadeSlideIn.staggered(
            6,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg)
                  .copyWith(bottom: AppSpacing.lg),
              child: TextButton(
                onPressed: () => _confirmAndDelete(context, ref),
                child: Text(
                  'Delete account',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          ),
        ],
      ),
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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This permanently deletes your profile, your messages and your '
            'connections. It cannot be undone.\n\nType DELETE to confirm.',
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _controller,
            autocorrect: false,
            onTapOutside: (_) => FocusScope.of(context).unfocus(),
            decoration: const InputDecoration(hintText: 'DELETE'),
            onChanged: (_) => setState(() {}),
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
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
