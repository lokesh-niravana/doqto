import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/motion.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../core/utils/validators.dart';
import '../../../data/services/auth_broker.dart';
import '../../../state/auth_state.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/inline_banner.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/phone_field.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/social_button.dart';

/// Sign-in. One screen, several ways in: phone, Google, Facebook, Apple, and
/// email + password.
///
/// Every route except email/password is brokered by Firebase and ends in the
/// same place — one ID token, exchanged for a Doqto session. There is no
/// separate sign-up: the identity decides. Email + password is still frontend
/// only.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

enum _Method { phone, email }

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneKey = GlobalKey<PhoneFieldState>();
  final _identifierKey = GlobalKey<AppTextFieldState>();
  final _passwordKey = GlobalKey<AppTextFieldState>();
  final _identifier = TextEditingController();
  final _password = TextEditingController();

  _Method _method = _Method.phone;
  String _e164 = '';
  bool _loading = false;
  bool _obscure = true;
  String? _submitError;
  String? _notice;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  void _clearMessages() {
    if (_submitError != null || _notice != null) {
      setState(() {
        _submitError = null;
        _notice = null;
      });
    }
  }

  /// Email + password is still frontend-only.
  void _notYetAvailable() {
    FocusScope.of(context).unfocus();
    setState(() {
      _submitError = null;
      _notice = Strings.loginComingSoon;
    });
  }

  Future<void> _social(SocialProvider provider) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _submitError = null;
      _notice = null;
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
      _notice = null;
    });
    try {
      // Firebase sends the SMS and hands back a challenge; the code screen
      // gives it straight back when the user types the code.
      final challenge =
          await ref.read(authProvider.notifier).startPhoneSignIn(_e164);
      if (!mounted) return;
      context.push(AppRoutes.otp, extra: challenge);
    } catch (e) {
      setState(() => _submitError = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _signInWithPassword() {
    // Validate first so the form behaves exactly as it will once the endpoint
    // exists — the user sees field errors, not a blanket notice.
    final identifierOk = _identifierKey.currentState?.validate() ?? false;
    final passwordOk = _passwordKey.currentState?.validate() ?? false;
    if (!identifierOk || !passwordOk) return;
    _notYetAvailable();
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
                  FadeSlideIn.staggered(
                    1,
                    AppSegmented(
                      tabs: const [
                        Strings.loginTabPhone,
                        Strings.loginTabEmail,
                      ],
                      index: _method.index,
                      onChanged: (i) {
                        FocusScope.of(context).unfocus();
                        setState(() {
                          _method = _Method.values[i];
                          _submitError = null;
                          _notice = null;
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  // Height differs between the two forms — animate so the buttons
                  // below slide rather than jump.
                  FadeSlideIn.staggered(
                    2,
                    AnimatedSize(
                      duration: AppMotion.maybe(context, AppMotion.enter),
                      curve: AppMotion.curveEnter,
                      alignment: Alignment.topCenter,
                      child: _method == _Method.phone
                          ? _phoneForm()
                          : _emailForm(),
                    ),
                  ),
                  InlineError(_submitError),
                  if (_notice != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    InlineBanner(
                      tone: BannerTone.info,
                      icon: Icons.info_outline,
                      text: _notice!,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  FadeSlideIn.staggered(3, _divider()),
                  const SizedBox(height: AppSpacing.lg),
                  FadeSlideIn.staggered(
                    4,
                    SocialButton.google(
                      label: Strings.loginGoogle,
                      onPressed:
                          _loading ? null : () => _social(SocialProvider.google),
                    ),
                  ),
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
                  const SizedBox(height: AppSpacing.md),
                  FadeSlideIn.staggered(
                    6,
                    SocialButton.apple(
                      label: Strings.loginApple,
                      onPressed:
                          _loading ? null : () => _social(SocialProvider.apple),
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
      key: const ValueKey(_Method.phone),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PhoneField(
          key: _phoneKey,
          helperText: Strings.loginPhoneHelper,
          onChanged: (full) {
            _e164 = full;
            _clearMessages();
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

  Widget _emailForm() {
    return Column(
      key: const ValueKey(_Method.email),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTextField(
          key: _identifierKey,
          controller: _identifier,
          label: Strings.loginIdentifier,
          hint: Strings.loginIdentifierHint,
          keyboardType: TextInputType.emailAddress,
          validator: Validators.usernameOrEmail(),
          onChanged: (_) => _clearMessages(),
        ),
        const SizedBox(height: AppSpacing.md),
        AppTextField(
          key: _passwordKey,
          controller: _password,
          label: Strings.loginPassword,
          hint: Strings.loginPasswordHint,
          obscure: _obscure,
          validator: Validators.password(),
          onChanged: (_) => _clearMessages(),
          suffix: IconButton(
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(
              _obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
              color: AppColors.textMuted,
            ),
            tooltip: _obscure ? 'Show password' : 'Hide password',
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _notYetAvailable,
            child: Text(
              Strings.loginForgotPassword,
              style: AppText.caption.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          label: Strings.loginSignIn,
          onPressed: _signInWithPassword,
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
