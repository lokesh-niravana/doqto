import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/di/providers.dart';
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

enum _PinMode { idle, enable, change, disable }

/// Settings → Two-step verification (batch 6). A 6-digit PIN every new
/// device must enter after OTP. Off: turn on (PIN twice). On: change
/// (current + new twice) or turn off (PIN).
class TwoStepPinScreen extends ConsumerStatefulWidget {
  const TwoStepPinScreen({super.key});

  @override
  ConsumerState<TwoStepPinScreen> createState() => _TwoStepPinScreenState();
}

class _TwoStepPinScreenState extends ConsumerState<TwoStepPinScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  _PinMode _mode = _PinMode.idle;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _start(_PinMode mode) {
    _current.clear();
    _pin.clear();
    _confirm.clear();
    setState(() {
      _mode = mode;
      _error = null;
    });
  }

  Future<void> _save() async {
    final l = context.l10n;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_mode != _PinMode.disable && _pin.text != _confirm.text) {
      setState(() => _error = l.pinMismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(settingsRepositoryProvider);
    final auth = ref.read(authProvider.notifier);
    final user = ref.read(authProvider).user;
    try {
      String toast;
      switch (_mode) {
        case _PinMode.enable:
          await repo.setPin(_pin.text);
          if (user != null) auth.setUser(user.copyWith(pinEnabled: true));
          toast = l.pinEnabledToast;
        case _PinMode.change:
          await repo.setPin(_pin.text, currentPin: _current.text);
          toast = l.pinChangedToast;
        case _PinMode.disable:
          await repo.disablePin(_current.text);
          if (user != null) auth.setUser(user.copyWith(pinEnabled: false));
          toast = l.pinDisabledToast;
        case _PinMode.idle:
          return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(toast)));
      _start(_PinMode.idle);
    } catch (e) {
      if (mounted) setState(() => _error = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _pinField(TextEditingController c, String key, String label, {bool autofocus = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppTextField(
        key: ValueKey(key),
        controller: c,
        label: label,
        keyboardType: TextInputType.number,
        obscure: true,
        autofocus: autofocus,
        maxLength: AppConstants.otpLength,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        validator: Validators.otp(AppConstants.otpLength),
        dismissOnValid: true,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final enabled = ref.watch(authProvider).user?.pinEnabled ?? false;
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.settingsTwoStep)),
      body: ListView(
        key: const ValueKey('pin-screen'),
        padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
        children: [
          FadeSlideIn.staggered(
            0,
            Row(
              children: [
                Icon(Icons.pin_rounded, color: AppColors.medBlue, size: 32),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    enabled ? l.pinOnFooter : l.pinOffFooter,
                    style: AppText.body,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          if (_mode == _PinMode.idle) ...[
            if (!enabled)
              AppButton(
                key: const ValueKey('pin-turn-on'),
                label: l.pinTurnOn,
                expand: true,
                onPressed: () => _start(_PinMode.enable),
              )
            else ...[
              AppButton(
                key: const ValueKey('pin-change'),
                label: l.pinChange,
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: () => _start(_PinMode.change),
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                key: const ValueKey('pin-off'),
                label: l.pinTurnOff,
                variant: AppButtonVariant.danger,
                expand: true,
                onPressed: () => _start(_PinMode.disable),
              ),
            ],
          ] else
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_mode != _PinMode.enable)
                    _pinField(_current, 'pin-current', l.pinCurrent, autofocus: true),
                  if (_mode != _PinMode.disable) ...[
                    _pinField(_pin, 'pin-new', l.pinNew, autofocus: _mode == _PinMode.enable),
                    _pinField(_confirm, 'pin-confirm', l.pinConfirm),
                  ],
                  InlineError(_error),
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    key: const ValueKey('pin-save'),
                    label: _mode == _PinMode.disable ? l.pinTurnOff : l.commonSave,
                    variant: _mode == _PinMode.disable
                        ? AppButtonVariant.danger
                        : AppButtonVariant.primary,
                    loading: _busy,
                    expand: true,
                    onPressed: _busy ? null : _save,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextButton(
                    key: const ValueKey('pin-cancel'),
                    onPressed: _busy ? null : () => _start(_PinMode.idle),
                    child: Text(l.commonCancel),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
