import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';

/// Phone input with a country-code picker on the left and national-number
/// field on the right. Emits the full E.164 string (`+<code><national>`) via
/// [onChanged]. Styling follows the same tokens as [AppTextField] so the
/// wider auth UI stays consistent.
///
/// Validation runs on blur (and on every change after first blur, like
/// [AppTextField]). Parents can call `state.validate()` via a GlobalKey
/// before submit.
class PhoneField extends StatefulWidget {
  /// The full E.164 number — `+<code><national>`. Passed every time the
  /// user changes the country OR the number.
  final ValueChanged<String> onChanged;

  /// Initial ISO 3166 code. Defaults to `US`.
  final String initialCountry;

  /// External error override (e.g. from server response). Wins over the
  /// widget's own parser output so screens can display
  /// `ErrorMessages.forApi(e)` after submit failures.
  final String? errorText;

  /// Called when the user changes country via the bottom sheet. Optional —
  /// most screens just need the composite via [onChanged].
  final ValueChanged<Country>? onCountryChanged;

  final String? helperText;
  final bool autofocus;

  /// Empty is valid. Only a number that was actually typed gets checked.
  final bool optional;

  const PhoneField({
    super.key,
    required this.onChanged,
    this.initialCountry = 'US',
    this.errorText,
    this.onCountryChanged,
    this.helperText,
    this.autofocus = false,
    this.optional = false,
  });

  @override
  State<PhoneField> createState() => PhoneFieldState();
}

class PhoneFieldState extends State<PhoneField> {
  late Country _country;
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String? _internalError;
  bool _hasBlurred = false;

  @override
  void initState() {
    super.initState();
    _country = _countryFromIso(widget.initialCountry);
    _focus.addListener(_onFocusChange);
    _controller.addListener(_emit);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.removeListener(_emit);
    _controller.dispose();
    super.dispose();
  }

  Country _countryFromIso(String iso) {
    try {
      return CountryService().findByCode(iso) ?? _defaultCountry();
    } catch (_) {
      return _defaultCountry();
    }
  }

  Country _defaultCountry() => CountryService().findByCode('US')!;

  /// Current full E.164 string.
  String get e164 {
    final digits = _controller.text.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    return '+${_country.phoneCode}$digits';
  }

  /// Force validation and return true if valid. Use before submit.
  bool validate() {
    _hasBlurred = true;
    return _runValidator();
  }

  void _emit() {
    widget.onChanged(e164);
    if (_hasBlurred) _runValidator();
    // ponytail: drop the keypad the moment the number is complete
    // (not when empty: an optional field is "valid" empty, and backspacing
    // the last digit must not snatch the keyboard away)
    if (_focus.hasFocus && e164.isNotEmpty && validationError() == null) {
      _focus.unfocus();
    }
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) {
      _hasBlurred = true;
      _runValidator();
    }
  }

  /// Validation message for the current input, or null when it parses clean.
  /// Pure — no setState, safe to call on every keystroke.
  @visibleForTesting
  String? validationError() {
    final digits = _controller.text.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      return widget.optional ? null : 'Please enter your phone number.';
    }
    try {
      final parsed = PhoneNumber.parse(
        digits,
        destinationCountry: IsoCode.values.byName(_country.countryCode),
      );
      if (!parsed.isValid()) {
        // The country by name: "a valid IN number" reads as a typo.
        return Strings.phoneInvalidFor(_country.name);
      }
    } catch (_) {
      return 'Please enter a valid phone number.';
    }
    return null;
  }

  bool _runValidator() {
    final error = validationError();
    if (error != _internalError) {
      setState(() => _internalError = error);
    }
    return error == null;
  }

  Future<void> _pickCountry() async {
    showCountryPicker(
      context: context,
      favorite: const ['US', 'IN', 'GB', 'CA', 'AU'],
      countryListTheme: CountryListThemeData(
        backgroundColor: AppColors.white,
        bottomSheetHeight: MediaQuery.of(context).size.height * 0.7,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        inputDecoration: InputDecoration(
          hintText: 'Search country',
          prefixIcon: Icon(Icons.search, color: AppColors.textSecondary),
          border: OutlineInputBorder(
            borderRadius: AppRadii.rMd,
            borderSide: BorderSide(color: AppColors.gray200),
          ),
        ),
        searchTextStyle: AppText.bodyPrimary,
        textStyle: AppText.bodyPrimary,
      ),
      onSelect: (c) {
        setState(() => _country = c);
        widget.onCountryChanged?.call(c);
        _emit();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final errorToShow = widget.errorText ?? _internalError;
    final hasError = errorToShow != null && errorToShow.isNotEmpty;

    final border = OutlineInputBorder(
      borderRadius: AppRadii.rMd,
      borderSide: BorderSide(
        color: hasError ? AppColors.red : AppColors.gray200,
        width: hasError ? 1.5 : 1,
      ),
    );
    final focusedBorder = OutlineInputBorder(
      borderRadius: AppRadii.rMd,
      borderSide: BorderSide(
        color: hasError ? AppColors.red : AppColors.medBlue,
        width: 1.5,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _CountryPill(
              country: _country,
              onTap: _pickCountry,
              hasError: hasError,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              // One node named "Phone number".
              child: Semantics(
                label: 'Phone number',
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  keyboardType: TextInputType.phone,
                  // Lets iOS offer the person's own number above the keyboard.
                  autofillHints: const [AutofillHints.telephoneNumberNational],
                  autofocus: widget.autofocus,
                  onTapOutside: (_) => _focus.unfocus(),
                  style: AppText.bodyPrimary,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9\s\-]')),
                    LengthLimitingTextInputFormatter(20),
                  ],
                  decoration: InputDecoration(
                    // Drawn only: an example number merged into the name
                    // would be read as "Phone number, 555 555 0100".
                    hint: ExcludeSemantics(
                      child: Text(
                        _exampleFor(_country.countryCode),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).inputDecorationTheme.hintStyle ??
                            AppText.body.copyWith(color: AppColors.textMuted),
                      ),
                    ),
                    enabledBorder: border,
                    focusedBorder: focusedBorder,
                    border: border,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs + 2),
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 14,
                    color: AppColors.red,
                  ),
                  const SizedBox(width: AppSpacing.xs + 2),
                  Expanded(
                    child: Text(
                      errorToShow,
                      style: AppText.caption.copyWith(color: AppColors.red),
                    ),
                  ),
                ],
              ),
            ),
          )
        else if (widget.helperText != null && widget.helperText!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(widget.helperText!, style: AppText.caption),
          ),
      ],
    );
  }

  String _exampleFor(String iso) {
    switch (iso) {
      case 'US':
      case 'CA':
        return '555 555 0100';
      case 'IN':
        return '98765 43210';
      case 'GB':
        return '7700 900123';
      case 'AU':
        return '4 1234 5678';
      default:
        return 'Phone number';
    }
  }
}

class _CountryPill extends StatelessWidget {
  final Country country;
  final VoidCallback onTap;
  final bool hasError;

  const _CountryPill({
    required this.country,
    required this.onTap,
    required this.hasError,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: 'Country code, ${country.name} +${country.phoneCode}',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: AppColors.white,
        borderRadius: AppRadii.rMd,
        child: InkWell(
          borderRadius: AppRadii.rMd,
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            decoration: BoxDecoration(
              borderRadius: AppRadii.rMd,
              border: Border.all(
                color: hasError ? AppColors.red : AppColors.gray200,
                width: hasError ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(country.flagEmoji, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: AppSpacing.xs + 2),
                Text('+${country.phoneCode}', style: AppText.bodyPrimary),
                const SizedBox(width: 2),
                Icon(
                  Icons.arrow_drop_down,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
