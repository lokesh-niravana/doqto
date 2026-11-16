import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/di/providers.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../core/utils/validators.dart';
import '../../../data/services/auth_broker.dart';
import '../../../l10n/l10n.dart';
import '../../../state/auth_state.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/phone_field.dart';
import '../../widgets/primary_button.dart';

/// Settings → Change number (batch 6). Firebase verifies the new number
/// (link to the current Firebase user), then `POST /me/change-phone` with
/// the fresh id token swaps it on the account. A refused swap (number in
/// use) just shows the error: the Firebase link is left for the server to
/// reconcile, never unlinked client-side.
class ChangeNumberScreen extends ConsumerStatefulWidget {
  const ChangeNumberScreen({super.key});

  @override
  ConsumerState<ChangeNumberScreen> createState() => _ChangeNumberScreenState();
}

class _ChangeNumberScreenState extends ConsumerState<ChangeNumberScreen> {
  final _phoneKey = GlobalKey<PhoneFieldState>();
  final _codeKey = GlobalKey<AppTextFieldState>();
  final _code = TextEditingController();
  String _e164 = '';
  PhoneChallenge? _challenge;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!(_phoneKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final c = await ref.read(authBrokerProvider).startPhoneSignIn(_e164);
      if (!mounted) return;
      setState(() => _challenge = c);
    } catch (e) {
      if (mounted) setState(() => _error = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final challenge = _challenge;
    if (challenge == null || _busy) return;
    if (!(_codeKey.currentState?.validate() ?? false)) return;
    final l = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final idToken = await ref
          .read(authBrokerProvider)
          .linkPhone(challenge, _code.text);
      final user = await ref
          .read(settingsRepositoryProvider)
          .changePhone(idToken);
      ref.read(authProvider.notifier).setUser(user);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.changeNumberDone(user.phone))));
      context.pop();
    } catch (e) {
      if (mounted) setState(() => _error = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final current = ref.watch(authProvider).user?.phone;
    final challenge = _challenge;
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.settingsChangeNumber)),
      body: ListView(
        key: const ValueKey('change-number-screen'),
        padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
        children: [
          FadeSlideIn.staggered(
            0,
            Text(
              current == null
                  ? l.changeNumberIntro
                  : l.changeNumberIntroCurrent(current),
              style: AppText.body,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          if (challenge == null) ...[
            FadeSlideIn.staggered(
              1,
              KeyedSubtree(
                key: const ValueKey('change-number-phone'),
                child: PhoneField(
                  key: _phoneKey,
                  autofocus: true,
                  onChanged: (full) {
                    _e164 = full;
                    if (_error != null) setState(() => _error = null);
                  },
                ),
              ),
            ),
            InlineError(_error),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              key: const ValueKey('change-number-send'),
              label: l.changeNumberSend,
              loading: _busy,
              expand: true,
              onPressed: _busy ? null : _send,
            ),
          ] else ...[
            Text(l.changeNumberSentTo(challenge.phone), style: AppText.caption),
            const SizedBox(height: AppSpacing.md),
            KeyedSubtree(
              key: const ValueKey('change-number-code'),
              child: AppTextField(
                key: _codeKey,
                controller: _code,
                hint: l.changeNumberCodeHint,
                keyboardType: TextInputType.number,
                maxLength: AppConstants.otpLength,
                autofocus: true,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: Validators.otp(AppConstants.otpLength),
                dismissOnValid: true,
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
            ),
            InlineError(_error),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              key: const ValueKey('change-number-verify'),
              label: l.changeNumberVerify,
              loading: _busy,
              expand: true,
              onPressed: _busy ? null : _verify,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              key: const ValueKey('change-number-back'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _challenge = null;
                      _code.clear();
                      _error = null;
                    }),
              child: Text(l.changeNumberEditNumber),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          Text(l.changeNumberFooter, style: AppText.caption),
        ],
      ),
    );
  }
}
