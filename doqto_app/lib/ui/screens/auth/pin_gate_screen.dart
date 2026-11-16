import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../core/utils/validators.dart';
import '../../../l10n/l10n.dart';
import '../../../state/auth_state.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/primary_button.dart';

/// Two-step PIN gate (batch 6): shown after OTP on a device that has not
/// entered the account PIN yet. Six digits verify and route by the resolved
/// auth stage; "Forgot PIN?" starts the 7-day removal wait.
class PinGateScreen extends ConsumerStatefulWidget {
  const PinGateScreen({super.key});

  @override
  ConsumerState<PinGateScreen> createState() => _PinGateScreenState();
}

class _PinGateScreenState extends ConsumerState<PinGateScreen> {
  final _key = GlobalKey<AppTextFieldState>();
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_busy) return;
    if (!(_key.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).verifyPin(_controller.text);
      if (!mounted) return;
      final stage = ref.read(authProvider).stage;
      context.go(switch (stage) {
        AuthStage.signedIn => AppRoutes.chats,
        AuthStage.pendingVerification => AppRoutes.pending,
        AuthStage.needsOrg => AppRoutes.orgSelection,
        AuthStage.needsRegistration => AppRoutes.registration,
        AuthStage.pinRequired => AppRoutes.pinGate,
        _ => AppRoutes.login,
      });
    } catch (e) {
      if (!mounted) return;
      _controller.clear();
      setState(() => _error = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final l = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.pinGateForgotTitle),
        content: Text(l.pinGateForgotBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.commonCancel),
          ),
          TextButton(
            key: const ValueKey('pin-gate-forgot-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.pinGateForgotAction),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(authProvider.notifier).requestPinReset();
    } catch (e) {
      if (mounted) setState(() => _error = ErrorMessages.forApi(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final clearsAt = ref.watch(authProvider).pinClearsAt;
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(
        title: Text(l.pinGateTitle),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.xl),
              FadeSlideIn.staggered(
                0,
                Text(l.pinGateTitle, style: AppText.display),
              ),
              const SizedBox(height: AppSpacing.xs),
              FadeSlideIn.staggered(
                1,
                Text(l.pinGateBody, style: AppText.caption),
              ),
              const SizedBox(height: AppSpacing.lg),
              FadeSlideIn.staggered(
                2,
                KeyedSubtree(
                  key: const ValueKey('pin-gate-input'),
                  child: AppTextField(
                    key: _key,
                    controller: _controller,
                    hint: l.pinGateHint,
                    keyboardType: TextInputType.number,
                    obscure: true,
                    maxLength: AppConstants.otpLength,
                    autofocus: true,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: Validators.otp(AppConstants.otpLength),
                    dismissOnValid: true,
                    onChanged: (v) {
                      if (_error != null) setState(() => _error = null);
                      if (v.length == AppConstants.otpLength) _verify();
                    },
                  ),
                ),
              ),
              InlineError(_error),
              if (clearsAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.md),
                  child: Text(
                    l.pinGateResetPending(
                      DateFormat.yMMMd().format(clearsAt.toLocal()),
                    ),
                    key: const ValueKey('pin-gate-pending'),
                    style: AppText.body.copyWith(color: AppColors.amber),
                  ),
                ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                key: const ValueKey('pin-gate-continue'),
                label: l.pinGateContinue,
                loading: _busy,
                expand: true,
                onPressed: _busy ? null : _verify,
              ),
              const Spacer(),
              if (clearsAt == null)
                TextButton(
                  key: const ValueKey('pin-gate-forgot'),
                  onPressed: _busy ? null : _forgot,
                  child: Text(l.pinGateForgot),
                ),
              TextButton(
                key: const ValueKey('pin-gate-sign-out'),
                onPressed: () => ref.read(authProvider.notifier).signOut(),
                child: Text(
                  l.settingsSignOut,
                  style: TextStyle(color: AppColors.red),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
