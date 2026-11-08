import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../core/utils/validators.dart';
import 'fade_slide_in.dart';

/// Global reusable input field.
///
/// Features:
///  * Label above, helper text below.
///  * Inline error text below (red, icon-prefixed) — shown when [errorText]
///    is non-null OR when an auto-validator runs and returns an error.
///  * Auto-validate via the [validator] param. Runs on blur, and on every
///    change after the first blur (classic form UX: don't nag while typing
///    the first time, but show live feedback once the user has committed).
///  * Parents can imperatively validate via a [GlobalKey<AppTextFieldState>]
///    and call `state.validate()` before submit — returns true if valid.
///
/// Never re-implement a text field in screens — use this.
class AppTextField extends StatefulWidget {
  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final String? helperText;
  final String? errorText;
  final TextInputType? keyboardType;
  final bool obscure;
  final int? maxLength;
  final List<TextInputFormatter>? inputFormatters;
  final void Function(String)? onChanged;
  final TextStyle? style;
  final bool autofocus;

  /// Optional validator — if provided, [AppTextField] renders its error in red.
  final Validator? validator;

  /// Drop the keyboard as soon as [validator] passes. For fixed-length inputs
  /// (OTP, PIN) where "valid" means "done typing". Leave false for free text —
  /// a name validator passes at one character.
  final bool dismissOnValid;

  /// Defaults to Words (names, places); pass sentences for free prose.
  final TextCapitalization? textCapitalization;

  /// Optional trailing widget inside the frame (e.g. a password eye toggle).
  final Widget? suffix;

  /// Supply a focus node when something outside needs it (an autocomplete
  /// wrapper, say). The owner disposes it; the field only borrows it.
  final FocusNode? focusNode;

  /// Lines the field grows to (1 = single line). Multi-line fields keep the
  /// same tap-outside dismissal — the return key inserts a newline.
  final int maxLines;

  const AppTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.helperText,
    this.errorText,
    this.keyboardType,
    this.obscure = false,
    this.maxLength,
    this.inputFormatters,
    this.onChanged,
    this.style,
    this.autofocus = false,
    this.validator,
    this.dismissOnValid = false,
    this.textCapitalization,
    this.suffix,
    this.focusNode,
    this.maxLines = 1,
  });

  @override
  State<AppTextField> createState() => AppTextFieldState();
}

class AppTextFieldState extends State<AppTextField> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  bool get _ownsFocus => widget.focusNode == null;
  String? _internalError;
  bool _hasBlurred = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    if (_ownsFocus) _focus.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    setState(() => _focused = _focus.hasFocus);
    if (!_focus.hasFocus) {
      _hasBlurred = true;
      _runValidator(widget.controller?.text ?? '');
    }
  }

  bool _runValidator(String value) {
    if (widget.validator == null) return true;
    final error = widget.validator!(value);
    if (error != _internalError) {
      setState(() => _internalError = error);
    }
    return error == null;
  }

  /// Call from the parent before submit. Marks the field as "blurred" so the
  /// error sticks, runs the validator, and returns true if the value is valid.
  bool validate() {
    _hasBlurred = true;
    return _runValidator(widget.controller?.text ?? '');
  }

  void _onChanged(String value) {
    widget.onChanged?.call(value);
    if (_hasBlurred) _runValidator(value);
    if (widget.dismissOnValid &&
        _focus.hasFocus &&
        widget.validator?.call(value) == null) {
      _focus.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Explicit errorText from parent wins over internal validator output.
    final errorToShow = widget.errorText ?? _internalError;
    final hasError = errorToShow != null && errorToShow.isNotEmpty;

    // Border color animates (error > focused > resting) via AnimatedContainer;
    // the TextField's own borders are disabled so the frame never snaps.
    // Width stays constant so layout never shifts.
    final borderColor = hasError
        ? AppColors.red
        : _focused
            ? AppColors.medBlue
            : AppColors.gray200;
    final noBorder = OutlineInputBorder(
      borderRadius: AppRadii.rMd,
      borderSide: BorderSide.none,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!, style: AppText.subheading),
          const SizedBox(height: AppSpacing.sm),
        ],
        AnimatedContainer(
          duration: AppMotion.maybe(context, AppMotion.micro),
          curve: AppMotion.standard,
          decoration: BoxDecoration(
            borderRadius: AppRadii.rMd,
            border: Border.all(color: borderColor, width: 1.5),
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            keyboardType: widget.keyboardType,
            textCapitalization: widget.textCapitalization ??
                (widget.keyboardType == TextInputType.emailAddress
                    ? TextCapitalization.none
                    : TextCapitalization.words),
            obscureText: widget.obscure,
            maxLines: widget.obscure ? 1 : widget.maxLines,
            maxLength: widget.maxLength,
            inputFormatters: widget.inputFormatters,
            onChanged: _onChanged,
            autofocus: widget.autofocus,
            // Tapping anywhere off the field dismisses the keyboard. Flutter's
            // default only does this on desktop; on mobile focus would stick.
            onTapOutside: (_) => _focus.unfocus(),
            style: widget.style ?? AppText.bodyPrimary,
            decoration: InputDecoration(
              hintText: widget.hint,
              counterText: '',
              suffixIcon: widget.suffix,
              border: noBorder,
              enabledBorder: noBorder,
              focusedBorder: noBorder,
            ),
          ),
        ),
        // Error/helper region animates size + entrance so appearing text
        // slides in instead of snapping.
        AnimatedSize(
          duration: AppMotion.maybe(context, AppMotion.enter),
          curve: AppMotion.curveEnter,
          alignment: Alignment.topLeft,
          child: hasError
              ? Padding(
                  key: ValueKey<String>(errorToShow),
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: FadeSlideIn(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 14, color: AppColors.red),
                        const SizedBox(width: AppSpacing.xs + 2),
                        Expanded(
                          child: Text(
                            errorToShow,
                            style:
                                AppText.caption.copyWith(color: AppColors.red),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : (widget.helperText != null && widget.helperText!.isNotEmpty)
                  ? Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Text(widget.helperText!, style: AppText.caption),
                    )
                  : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
