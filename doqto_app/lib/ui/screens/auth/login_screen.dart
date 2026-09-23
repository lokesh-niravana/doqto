import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/services/auth_broker.dart';
import '../../../state/auth_state.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/phone_field.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/social_button.dart';

/// Sign-in. One screen, three ways in: phone, Google, Apple (Facebook once
/// the Meta app exists). All brokered by Firebase and all ending in the same
/// place — one ID token, exchanged for a Doqto session. There is no separate
/// sign-up: the identity decides.
/// ponytail: off until the Meta app (and its App ID) exists. With no App ID
/// in Info.plist the Facebook SDK throws a native exception on login, so a
/// visible button is a crash in a tester's hands. Flip to true once
/// FacebookAppID/FacebookClientToken are configured — docs/auth.md.
const bool kFacebookSignInEnabled = false;

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneKey = GlobalKey<PhoneFieldState>();

  String _e164 = '';
  bool _loading = false;
  String? _submitError;

  void _clearError() {
    if (_submitError != null) setState(() => _submitError = null);
  }

  Future<void> _social(SocialProvider provider) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _submitError = null;
    });
    try {
      await ref.read(authProvider.notifier).signInWith(provider);
      if (!mounted) return;
      // A dismissed provider sheet leaves the stage untouched — stay put.
      final stage = ref.read(authProvider).stage;
      if (stage == AuthStage.unknown || stage == AuthStage.signedOut) return;
      context.go(switch (stage) {
        AuthStage.needsRegistration => AppRoutes.registration,
        AuthStage.needsPayment => AppRoutes.payments,
        AuthStage.needsSubscription => AppRoutes.paywall,
        AuthStage.needsOrg => AppRoutes.orgSelection,
        AuthStage.pendingVerification => AppRoutes.pending,
        _ => AppRoutes.chats,
      });
    } catch (e) {
      setState(() => _submitError = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendCode() async {
    if (!(_phoneKey.currentState?.validate() ?? false)) return;
    setState(() {
      _loading = true;
      _submitError = null;
    });
    try {
      // Firebase sends the SMS and hands back a challenge; the code screen
      // gives it straight back when the user types the code.
      final challenge = await ref
          .read(authProvider.notifier)
          .startPhoneSignIn(_e164);
      if (!mounted) return;
      context.push(AppRoutes.otp, extra: challenge);
    } catch (e) {
      setState(() => _submitError = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.fromLTRB(
      AppSpacing.screenHorizontal,
      AppSpacing.xl,
      AppSpacing.screenHorizontal,
      AppSpacing.xl,
    );
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: padding,
            child: ConstrainedBox(
              // Fill the viewport so the column has room to push its children
              // down. Taller content (small screens, keyboard open) overflows
              // this minimum and scrolls instead of clipping.
              constraints: BoxConstraints(
                minHeight: math.max(
                  0,
                  constraints.maxHeight - padding.vertical,
                ),
              ),
              child: Column(
                // Bottom-aligned: every control sits in the thumb zone and the
                // slack collects above the logo.
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FadeSlideIn.staggered(
                    0,
                    Center(
                      child: Image.asset('logo.png', width: 72, height: 72),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  FadeSlideIn.staggered(2, _phoneForm()),
                  InlineError(_submitError),
                  const SizedBox(height: AppSpacing.lg),
                  FadeSlideIn.staggered(3, _divider()),
                  const SizedBox(height: AppSpacing.lg),
                  FadeSlideIn.staggered(
                    4,
                    SocialButton.google(
                      label: Strings.loginGoogle,
                      onPressed: _loading
                          ? null
                          : () => _social(SocialProvider.google),
                    ),
                  ),
                  if (kFacebookSignInEnabled) ...[
                    const SizedBox(height: AppSpacing.md),
                    FadeSlideIn.staggered(
                      5,
                      SocialButton.facebook(
                        label: Strings.loginFacebook,
                        onPressed: _loading
                            ? null
                            : () => _social(SocialProvider.facebook),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  FadeSlideIn.staggered(
                    6,
                    SocialButton.apple(
                      label: Strings.loginApple,
                      onPressed: _loading
                          ? null
                          : () => _social(SocialProvider.apple),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _phoneForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PhoneField(
          key: _phoneKey,
          helperText: Strings.loginPhoneHelper,
          onChanged: (full) {
            _e164 = full;
            _clearError();
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          label: Strings.authSendOtp,
          onPressed: _sendCode,
          loading: _loading,
          expand: true,
        ),
      ],
    );
  }

  Widget _divider() {
    final line = Expanded(child: Divider(color: AppColors.border, height: 1));
    return Row(
      children: [
        line,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Text(Strings.loginDividerOr, style: AppText.caption),
        ),
        line,
      ],
    );
  }
}
