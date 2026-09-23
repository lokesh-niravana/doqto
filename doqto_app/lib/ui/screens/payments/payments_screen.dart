import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/api/api_client.dart';
import '../../../data/models/billing.dart';
import '../../../state/auth_state.dart';
import '../../../state/billing_state.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';

enum PaymentsMode {
  /// Straight after registration: start the trial, or subscribe now.
  onboarding,

  /// The trial is over. No way past this screen except paying.
  paywall,
}

/// Plan picker. After registration it offers the free trial or a subscription;
/// once the trial is over it is the paywall, with only a subscription.
///
/// Subscribing opens Stripe Checkout in the real browser (Apple's link-out
/// rule for web payments) and polls until the webhook has landed.
class PaymentsScreen extends ConsumerStatefulWidget {
  final PaymentsMode mode;
  const PaymentsScreen({super.key, this.mode = PaymentsMode.onboarding});

  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _Plan {
  final String id;
  final String name;
  final String price;
  final String? note;
  const _Plan(this.id, this.name, this.price, [this.note]);
}

/// Shown while billing loads or when the server can't be reached, so the
/// screen is never empty. The server's prices replace these as soon as they
/// arrive.
const _fallback = Billing(
  entitled: false,
  reason: 'expired',
  monthlyCents: 899,
  yearlyCents: 8000,
);

List<_Plan> _plansFor(Billing b) => [
      _Plan('monthly', Strings.planMonthly, b.monthlyLabel),
      _Plan(
        'yearly',
        Strings.planYearly,
        b.yearlyLabel,
        Strings.planSaving(b.yearlySavingPercent, b.yearlyPerMonthLabel),
      ),
    ];

class _PaymentsScreenState extends ConsumerState<PaymentsScreen> {
  // Yearly is the better deal, so it starts selected.
  String _selected = 'yearly';
  bool _loading = false;
  bool _subscribing = false;
  bool _checking = false;
  String? _error;

  bool get _paywall => widget.mode == PaymentsMode.paywall;
  bool get _busy => _loading || _subscribing || _checking;

  Future<void> _leave() async {
    setState(() => _loading = true);
    // No explicit navigation: the router's redirect owns where a resolved auth
    // stage lands. It sends a signed-in user to chats and one whose org is
    // still under review to the pending screen — a hardcoded go(chats) would
    // get the second case wrong.
    await ref.read(authProvider.notifier).completePayment();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _subscribe() async {
    setState(() {
      _subscribing = true;
      _error = null;
    });
    try {
      final url = await ref.read(billingRepositoryProvider).checkoutUrl(_selected);
      await ref.read(urlOpenerProvider).open(url);
      final billing =
          await ref.read(billingProvider.notifier).pollAfterCheckout();
      // Paid: re-resolve the stage and let the router take them onward.
      if (billing?.entitled == true) {
        await ref.read(authProvider.notifier).recheckSubscription();
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _subscribing = false);
    }
  }

  /// "I have already paid": the webhook may have landed while the app was in
  /// the background. The server still has the final word.
  Future<void> _checkPaid() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    await ref.read(billingProvider.notifier).pollAfterCheckout();
    await ref.read(authProvider.notifier).recheckSubscription();
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _signOut() => ref.read(authProvider.notifier).signOut();

  Widget _textButton(String label, VoidCallback onTap) => Center(
        child: AppPressable(
          onTap: _busy ? null : onTap,
          minTarget: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              label,
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final billing = ref.watch(billingProvider).value ?? _fallback;
    final plans = _plansFor(billing);

    final actions = <Widget>[
      if (_paywall) ...[
        AppButton(
          label: Strings.planSubscribe,
          onPressed: _busy ? null : _subscribe,
          loading: _subscribing,
          expand: true,
        ),
        const SizedBox(height: AppSpacing.sm),
        _checking
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.md),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : _textButton(Strings.paywallPaid, _checkPaid),
        _textButton(Strings.paywallSignOut, _signOut),
      ] else ...[
        AppButton(
          label: Strings.planStartTrial,
          onPressed: _busy ? null : _leave,
          loading: _loading,
          expand: true,
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton(
          label: Strings.planSubscribe,
          variant: AppButtonVariant.secondary,
          onPressed: _busy ? null : _subscribe,
          loading: _subscribing,
          expand: true,
        ),
        const SizedBox(height: AppSpacing.sm),
        _textButton(Strings.planSkip, _leave),
      ],
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_paywall ? Strings.paywallTitle : Strings.planTitle),
        // The paywall is a stage, not a page: there is nothing to go back to.
        automaticallyImplyLeading: !_paywall,
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: AppSpacing.sm),
                    FadeSlideIn.staggered(
                      0,
                      Text(
                        _paywall ? Strings.paywallBody : Strings.planSubtitle,
                        style: AppText.body,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    for (final (i, plan) in plans.indexed) ...[
                      FadeSlideIn.staggered(
                        i + 1,
                        _PlanCard(
                          plan: plan,
                          selected: plan.id == _selected,
                          onTap: () => setState(() => _selected = plan.id),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    const Spacer(),
                    if (_error case final error?) ...[
                      Text(
                        error,
                        textAlign: TextAlign.center,
                        style: AppText.caption.copyWith(color: AppColors.red),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    FadeSlideIn.staggered(
                      plans.length + 1,
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: actions,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final _Plan plan;
  final bool selected;
  final VoidCallback onTap;

  const _PlanCard({required this.plan, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppPressable(
      onTap: onTap,
      haptic: true,
      child: Semantics(
        selected: selected,
        button: true,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: selected ? AppColors.medBlueLight : AppColors.surface,
            borderRadius: AppRadii.rLg,
            border: Border.all(
              color: selected ? AppColors.medBlue : AppColors.gray200,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(plan.name, style: AppText.subheading),
                    if (plan.note case final note?) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(note, style: AppText.caption),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Text(plan.price, style: AppText.subheading),
              const SizedBox(width: AppSpacing.md),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? AppColors.medBlue : AppColors.gray400,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
