import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../core/utils/validators.dart';
import '../../../data/services/npi_lookup.dart';
import '../../../data/services/auth_broker.dart';
import '../../../state/auth_state.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/phone_field.dart';
import '../../widgets/specialty_field.dart';

/// Registration, prefilled from the public CMS NPI registry — see
/// `docs/npi-lookup.md`. The lookup is best-effort: it never blocks Continue,
/// never overwrites something the user typed, and stays silent when it fails.
class RegistrationScreen extends ConsumerStatefulWidget {
  const RegistrationScreen({super.key});

  @override
  ConsumerState<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends ConsumerState<RegistrationScreen> {
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _specialty = TextEditingController();
  final _npi = TextEditingController();

  final _firstKey = GlobalKey<AppTextFieldState>();
  final _lastKey = GlobalKey<AppTextFieldState>();
  final _npiKey = GlobalKey<AppTextFieldState>();

  bool _loading = false;
  String? _submitError;
  String? _specialtyError;

  /// Only people who signed up without a phone (social sign-in) are asked for
  /// one. Decided once: verifying puts a phone on the user, and the section
  /// must not vanish the moment it succeeds.
  late final bool _askPhone =
      ref.read(authProvider).user?.phone.isEmpty ?? false;

  /// A number is typed but not verified yet. Optional means empty is fine —
  /// not that an unverified number gets through.
  bool _phonePending = false;
  String? _phoneError;

  // --- Lookup state (see the state machine in docs/npi-lookup.md) ---
  NpiMatch? _match;
  bool _ambiguous = false;

  /// The name query we last sent, so an unchanged name never re-queries.
  String? _lastNameQuery;

  /// Once the user identifies themselves by NPI, the name path stops firing.
  bool _matchedByNpi = false;

  /// The card was dismissed for the current match — don't re-show it.
  bool _dismissed = false;

  /// Which fields we filled and the user hasn't touched since. Only these may
  /// be overwritten by a later lookup.
  bool _npiAuto = false;
  bool _specialtyAuto = false;

  String? _city;
  String? _state;

  @override
  void initState() {
    super.initState();
    // Google/Apple already told us the name; typing it again is friction.
    // Split on the first space: Firebase gives one display string.
    final name = ref.read(authBrokerProvider).profile?.name?.trim();
    if (name != null && name.isNotEmpty) {
      final i = name.indexOf(' ');
      _first.text = i < 0 ? name : name.substring(0, i);
      _last.text = i < 0 ? '' : name.substring(i + 1).trim();
    }
  }

  /// Who this form belongs to, so a wrong-account sign-in is obvious here
  /// rather than after registering. Email over phone: social users have no
  /// phone yet, and the email is what they just picked in the provider sheet.
  String get _identity {
    final user = ref.read(authProvider).user;
    final email = user?.email ?? ref.read(authBrokerProvider).profile?.email;
    // "Hide My Email" hands us st7gd696bw@privaterelay.appleid.com — real,
    // ours to keep, and meaningless to the person reading it.
    if (email != null && email.endsWith('@privaterelay.appleid.com')) {
      return Strings.regApplePrivateEmail;
    }
    return email ?? user?.phone ?? '';
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _specialty.dispose();
    _npi.dispose();
    super.dispose();
  }

  // ---------- Lookup ----------

  /// Fires when focus leaves the name block entirely. Moving between the two
  /// name fields keeps focus inside, so this runs once per completed name.
  Future<void> _lookupByName() async {
    if (_matchedByNpi) return;
    final first = _first.text.trim();
    final last = _last.text.trim();
    if (first.length < 2 || last.length < 2) return;

    final query = '$first|$last'.toLowerCase();
    if (query == _lastNameQuery) return;
    _lastNameQuery = query;

    final result = await _ask(() => ref.read(npiLookupProvider).byName(first, last));
    if (!mounted) return;
    setState(() {
      _dismissed = false;
      switch (result.outcome) {
        case NpiLookupOutcome.matched:
          _ambiguous = false;
          _apply(result.match!, fillNpi: true);
        case NpiLookupOutcome.ambiguous:
          _ambiguous = true;
          _match = null;
        case NpiLookupOutcome.none:
          _ambiguous = false;
          _match = null;
          // Might have been CMS being down rather than a genuine miss, so let
          // the same name be tried again. Real misses are cached in the
          // service, so the retry costs nothing.
          _lastNameQuery = null;
      }
    });
  }

  Future<void> _lookupByNpi(String npi) async {
    final result = await _ask(() => ref.read(npiLookupProvider).byNumber(npi));
    if (!mounted) return;
    setState(() {
      _dismissed = false;
      if (result.match != null) {
        _matchedByNpi = true;
        _ambiguous = false;
        // The user typed this NPI — filling it back in would be a no-op.
        _apply(result.match!, fillNpi: false);
      } else {
        // A card from an earlier name match no longer describes this NPI.
        _match = null;
      }
    });
  }

  /// The lookup is best-effort: a provider that throws must never reach the
  /// user or strand the spinner.
  Future<NpiLookupResult> _ask(Future<NpiLookupResult> Function() query) async {
    try {
      return await query();
    } catch (_) {
      return const NpiLookupResult.none();
    }
  }

  /// Caller already holds setState.
  void _apply(NpiMatch match, {required bool fillNpi}) {
    _match = match;
    if (fillNpi && (_npi.text.trim().isEmpty || _npiAuto)) {
      _npi.text = match.npi;
      _npiAuto = true;
    }
    final taxonomy = match.taxonomy;
    if (taxonomy != null && (_specialty.text.trim().isEmpty || _specialtyAuto)) {
      _specialty.text = taxonomy;
      _specialtyAuto = true;
    }
    _city = match.city;
    _state = match.state;
  }

  /// "Use these details" — the one case where the registry may overwrite what
  /// the user typed: they just asked it to.
  void _useMatch() {
    final match = _match;
    if (match == null) return;
    setState(() {
      if (match.firstName != null) _first.text = match.firstName!;
      if (match.lastName != null) _last.text = match.lastName!;
      if (match.taxonomy != null) {
        _specialty.text = match.taxonomy!;
        _specialtyAuto = true;
        _specialtyError = null;
      }
      _npi.text = match.npi;
      _npiAuto = true;
      _lastNameQuery = '${match.firstName}|${match.lastName}'.toLowerCase();
    });
  }

  /// "Not me" — drop the card and everything it filled, and don't re-query the
  /// same name.
  void _dismissMatch() {
    setState(() {
      _dismissed = true;
      _match = null;
      _matchedByNpi = false;
      _city = null;
      _state = null;
      if (_npiAuto) {
        _npi.clear();
        _npiAuto = false;
      }
      if (_specialtyAuto) {
        _specialty.clear();
        _specialtyAuto = false;
      }
    });
  }

  void _clearSubmitError() {
    if (_submitError != null) setState(() => _submitError = null);
  }

  // ---------- Submit ----------

  Future<void> _submit() async {
    // Validate every required field. Running all validators (not short-circuiting)
    // lets the user see every issue at once.
    final firstOk = _firstKey.currentState?.validate() ?? false;
    final lastOk = _lastKey.currentState?.validate() ?? false;
    final npiOk = _npiKey.currentState?.validate() ?? false;
    final specialtyError = Validators.required(Strings.regSpecialty)(_specialty.text);
    setState(() {
      _specialtyError = specialtyError;
      _phoneError = _phonePending ? Strings.regPhoneUnverified : null;
    });
    if (!firstOk || !lastOk || !npiOk || specialtyError != null || _phonePending) {
      return;
    }

    setState(() {
      _loading = true;
      _submitError = null;
    });
    try {
      // An in-flight lookup is irrelevant here — the user has told us enough.
      await ref.read(authProvider.notifier).completeRegistration(
            fullName: '${_first.text.trim()} ${_last.text.trim()}',
            specialty: _specialty.text.trim(),
            npiNumber: _npi.text.trim(),
            city: _city,
            practiceState: _state,
          );
      if (!mounted) return;
      context.go(AppRoutes.payments);
    } catch (e) {
      setState(() => _submitError = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final match = _match;
    return Scaffold(
      appBar: AppBar(title: const Text('Your details')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(Strings.regSignedInAs(_identity), style: AppText.caption),
                TextButton(
                  onPressed: () => ref.read(authProvider.notifier).signOut(),
                  child: const Text(Strings.regSignOut),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            // One Focus around both name fields: tabbing first → last keeps
            // focus inside, so the registry is queried once, on the way out.
            Focus(
              onFocusChange: (hasFocus) {
                if (!hasFocus) _lookupByName();
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FadeSlideIn.staggered(
                    0,
                    AppTextField(
                      key: _firstKey,
                      controller: _first,
                      label: '${Strings.regFirstName} *',
                      validator: Validators.personName(Strings.regFirstName),
                      onChanged: (_) => _clearSubmitError(),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FadeSlideIn.staggered(
                    1,
                    AppTextField(
                      key: _lastKey,
                      controller: _last,
                      label: '${Strings.regLastName} *',
                      validator: Validators.personName(Strings.regLastName),
                      onChanged: (_) => _clearSubmitError(),
                    ),
                  ),
                ],
              ),
            ),
            if (match != null && !_dismissed) ...[
              const SizedBox(height: AppSpacing.lg),
              FadeSlideIn(
                key: ValueKey<String>(match.npi),
                child: _MatchCard(
                  match: match,
                  onDismiss: _dismissMatch,
                  onUse: _useMatch,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            FadeSlideIn.staggered(
              2,
              SpecialtyField(
                controller: _specialty,
                label: '${Strings.regSpecialty} *',
                errorText: _specialtyError,
                onChanged: (_) {
                  _specialtyAuto = false;
                  if (_specialtyError != null) setState(() => _specialtyError = null);
                },
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FadeSlideIn.staggered(
              3,
              AppTextField(
                key: _npiKey,
                controller: _npi,
                label: '${Strings.regNpi} *',
                keyboardType: TextInputType.number,
                maxLength: 10,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                // Not a helper text: shown only when the name matched several
                // clinicians, to say what to do next.
                helperText: _ambiguous ? Strings.regNpiAmbiguous : null,
                validator: Validators.npi(),
                // A 10-digit NPI is a complete input: drop the keypad (there is
                // no return key on it) and look the number up.
                dismissOnValid: true,
                onChanged: (value) {
                  _clearSubmitError();
                  _npiAuto = false;
                  final npi = value.trim();
                  if (npi.length == 10 && npi != _match?.npi) _lookupByNpi(npi);
                },
              ),
            ),
            if (_askPhone) ...[
              const SizedBox(height: AppSpacing.lg),
              _OptionalPhone(
                errorText: _phoneError,
                onPendingChanged: (pending) => setState(() {
                  _phonePending = pending;
                  if (!pending) _phoneError = null;
                }),
              ),
            ],
            InlineError(_submitError),
            const SizedBox(height: AppSpacing.xl),
            FadeSlideIn.staggered(
              4,
              AppButton(
                label: Strings.regContinue,
                // Never gated on the lookup — it is a convenience, not a step.
                onPressed: _submit,
                loading: _loading,
                expand: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Who the registry thinks this is. Never overwrites the name on its own —
/// the user typed that — but offers to on request.
class _MatchCard extends StatelessWidget {
  final NpiMatch match;
  final VoidCallback onDismiss;
  final VoidCallback onUse;

  const _MatchCard({
    required this.match,
    required this.onDismiss,
    required this.onUse,
  });

  @override
  Widget build(BuildContext context) {
    final lines = [
      match.addressLine,
      match.cityStateZip,
      match.taxonomy,
    ].whereType<String>().where((l) => l.isNotEmpty);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.medBlueLight,
        borderRadius: AppRadii.rMd,
        border: Border.all(color: AppColors.medBlueMid),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  Strings.regMatchTitle,
                  style: AppText.caption.copyWith(color: AppColors.medBlueDark),
                ),
              ),
              GestureDetector(
                onTap: onDismiss,
                child: Text(
                  Strings.regMatchDismiss,
                  style: AppText.caption.copyWith(
                    color: AppColors.medBlue,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(match.displayName, style: AppText.subheading)),
              const SizedBox(width: AppSpacing.sm),
              Text('NPI ${match.npi}', style: AppText.caption),
            ],
          ),
          for (final line in lines) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(line, style: AppText.caption),
          ],
          const SizedBox(height: AppSpacing.sm),
          GestureDetector(
            onTap: onUse,
            child: Text(
              Strings.regMatchUse,
              style: AppText.caption.copyWith(
                color: AppColors.medBlue,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// Optional phone for people who signed up without one — social sign-in, not
/// live yet, so today nobody sees this. Empty is fine. A typed number has to
/// be verified by OTP; [onPendingChanged] tells the screen while it isn't, so
/// Continue can refuse it.
class _OptionalPhone extends ConsumerStatefulWidget {
  final ValueChanged<bool> onPendingChanged;
  final String? errorText;

  const _OptionalPhone({required this.onPendingChanged, this.errorText});

  @override
  ConsumerState<_OptionalPhone> createState() => _OptionalPhoneState();
}

class _OptionalPhoneState extends ConsumerState<_OptionalPhone> {
  static const _codeLength = 6;

  final _code = TextEditingController();
  String _phone = '';
  bool _codeSent = false;
  bool _verified = false;
  bool _busy = false;
  String? _error;

  bool get _valid => _phone.isNotEmpty && Validators.phone()(_phone) == null;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  PhoneChallenge? _challenge;

  /// Any edit — number or country — starts verification over.
  void _onPhone(String e164) {
    if (e164 == _phone) return;
    setState(() {
      _phone = e164;
      _codeSent = false;
      _challenge = null;
      _verified = false;
      _error = null;
      _code.clear();
    });
    widget.onPendingChanged(e164.isNotEmpty);
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
      _code.clear();
    });
    try {
      // Firebase sends the SMS; the challenge comes back to _verify.
      _challenge =
          await ref.read(authProvider.notifier).startPhoneSignIn(_phone);
      if (mounted) setState(() => _codeSent = true);
    } catch (e) {
      if (mounted) setState(() => _error = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify(String code) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final challenge = _challenge;
      if (challenge == null) throw StateError('no verification in flight');
      final idToken =
          await ref.read(authBrokerProvider).linkPhone(challenge, code);
      final user = await ref.read(userRepositoryProvider).linkPhone(idToken);
      ref.read(authProvider.notifier).setUser(user);
      if (!mounted) return;
      setState(() => _verified = true);
      widget.onPendingChanged(false);
    } catch (e) {
      if (mounted) setState(() => _error = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // No asterisk: this is the one field that may stay empty.
        Text(Strings.regPhone, style: AppText.subheading),
        const SizedBox(height: AppSpacing.sm),
        PhoneField(
          optional: true,
          onChanged: _onPhone,
          errorText: _codeSent ? null : (_error ?? widget.errorText),
        ),
        if (_verified) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              const Icon(Icons.check_circle_rounded,
                  size: 18, color: AppColors.greenDark),
              const SizedBox(width: AppSpacing.xs),
              Text(
                Strings.regPhoneVerified,
                style: AppText.caption.copyWith(color: AppColors.greenDark),
              ),
            ],
          ),
        ] else if (_valid && !_codeSent) ...[
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: Strings.regPhoneSendCode,
            variant: AppButtonVariant.secondary,
            loading: _busy,
            expand: true,
            onPressed: _send,
          ),
        ] else if (_valid && _codeSent) ...[
          const SizedBox(height: AppSpacing.lg),
          AppTextField(
            controller: _code,
            label: Strings.regPhoneCode,
            keyboardType: TextInputType.number,
            maxLength: _codeLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: Validators.otp(_codeLength),
            // Six digits is a complete code: drop the keypad and check it.
            dismissOnValid: true,
            errorText: _error ?? widget.errorText,
            onChanged: (v) {
              if (_error != null) setState(() => _error = null);
              if (v.length == _codeLength && !_busy) _verify(v);
            },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : _send,
              child: Text(Strings.authResend),
            ),
          ),
        ],
      ],
    );
  }
}
