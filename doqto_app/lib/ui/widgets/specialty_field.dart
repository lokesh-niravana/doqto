import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/constants/specialties.dart';
import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'app_text_field.dart';

/// Specialty picker: type to filter [Specialties.all], or choose
/// [Specialties.other] and write in something the list does not cover.
///
/// Picking "Other" leaves that word in the dropdown and opens a second field
/// underneath, carrying across whatever had been typed so far. From then on
/// the second field holds the answer.
///
/// [controller] always holds the value to submit, never the literal word
/// "Other". The NPI registry lookup can write a taxonomy straight into it and
/// the dropdown will show it.
class SpecialtyField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? helperText;

  /// Shown under whichever field currently holds the answer — the dropdown,
  /// or the write-in field in "Other" mode.
  final String? errorText;

  /// Fires with the effective value on every change, typed or picked.
  final ValueChanged<String>? onChanged;

  const SpecialtyField({
    super.key,
    required this.controller,
    required this.label,
    this.helperText,
    this.errorText,
    this.onChanged,
  });

  @override
  State<SpecialtyField> createState() => _SpecialtyFieldState();
}

class _SpecialtyFieldState extends State<SpecialtyField>
    with WidgetsBindingObserver {
  /// What the dropdown shows. In "Other" mode that is the word Other, which is
  /// why it cannot be the caller's controller.
  late final TextEditingController _picker =
      TextEditingController(text: widget.controller.text);

  /// The write-in answer, shown only in "Other" mode.
  final TextEditingController _custom = TextEditingController();

  final FocusNode _pickerFocus = FocusNode();
  final FocusNode _customFocus = FocusNode();

  bool _other = false;

  /// The last thing actually typed into the dropdown. Read on selecting
  /// "Other" — by then RawAutocomplete has already overwritten the field with
  /// the chosen option, so the query cannot be recovered from the controller.
  String _query = '';

  /// Set while we write to the caller's controller ourselves, so our own
  /// writes don't come back through [_onExternalValue] as if someone else
  /// had made them.
  bool _writingBack = false;

  /// The dropdown field's box: the options list measures the room between
  /// its bottom edge and the keyboard.
  final GlobalKey _fieldKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onExternalValue);
    _pickerFocus.addListener(_onPickerFocus);
    WidgetsBinding.instance.addObserver(this);
  }

  /// The keyboard arriving shrinks the viewport, which is what gives the
  /// form enough scroll range to bring the field to the top. (Read from the
  /// binding: under a Scaffold, MediaQuery's keyboard inset is already
  /// consumed and reads zero.)
  @override
  void didChangeMetrics() {
    if (_pickerFocus.hasFocus) _scrollFieldToTop();
  }

  void _onPickerFocus() {
    if (_pickerFocus.hasFocus) _scrollFieldToTop();
  }

  /// The options open downward, where the keyboard is. Put the field at the
  /// top of the viewport so the list has the whole space above the keyboard.
  void _scrollFieldToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pickerFocus.hasFocus) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0,
        duration: AppMotion.maybe(context, AppMotion.micro),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onExternalValue);
    _pickerFocus.removeListener(_onPickerFocus);
    _picker.dispose();
    _custom.dispose();
    _pickerFocus.dispose();
    _customFocus.dispose();
    super.dispose();
  }

  /// Someone outside set the value — the NPI lookup, or a reset. Show it in
  /// the dropdown and drop out of "Other".
  void _onExternalValue() {
    if (_writingBack) return;
    setState(() {
      _other = false;
      _custom.clear();
      _query = '';
      _picker.text = widget.controller.text;
    });
  }

  void _publish(String value) {
    _writingBack = true;
    widget.controller.text = value;
    _writingBack = false;
    widget.onChanged?.call(value);
  }

  void _onSelected(String option) {
    if (option != Specialties.other) {
      setState(() {
        _other = false;
        _custom.clear();
        _query = '';
        _picker.text = option;
      });
      _pickerFocus.unfocus();
      _publish(option);
      return;
    }

    // "Other": keep the word in the dropdown, carry the half-typed query into
    // the write-in field, and put the caret at the end of it.
    final carried = _query.trim();
    setState(() {
      _other = true;
      _picker.text = Specialties.other;
      _custom.text = carried;
    });
    _custom.selection = TextSelection.collapsed(offset: carried.length);
    _publish(carried);
    _customFocus.requestFocus();
  }

  /// Typing in the dropdown means they are picking again, so the write-in
  /// field goes away.
  void _onPickerChanged(String value) {
    _query = value;
    if (_other) {
      setState(() {
        _other = false;
        _custom.clear();
      });
    }
    _publish(value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RawAutocomplete<String>(
          textEditingController: _picker,
          focusNode: _pickerFocus,
          // In "Other" mode the field reads "Other", which would otherwise
          // filter the list down to that one entry. Show everything instead,
          // so tapping it is still a way to change your mind.
          optionsBuilder: (value) => Specialties.matching(
            _other && value.text == Specialties.other ? '' : value.text,
          ),
          onSelected: _onSelected,
          fieldViewBuilder: (context, controller, focusNode, _) => AppTextField(
            key: _fieldKey,
            controller: controller,
            focusNode: focusNode,
            label: widget.label,
            helperText: _other ? null : widget.helperText,
            errorText: _other ? null : widget.errorText,
            onChanged: _onPickerChanged,
            suffix: Icon(Icons.arrow_drop_down, color: AppColors.textMuted),
          ),
          optionsViewBuilder: (context, onSelected, options) => Align(
            alignment: Alignment.topLeft,
            child: _OptionsList(
              options: options,
              onSelected: onSelected,
              fieldKey: _fieldKey,
            ),
          ),
        ),
        if (_other) ...[
          const SizedBox(height: AppSpacing.lg),
          AppTextField(
            controller: _custom,
            focusNode: _customFocus,
            label: Strings.regSpecialtyOther,
            hint: Strings.regSpecialtyOtherHint,
            errorText: widget.errorText,
            onChanged: _publish,
          ),
        ],
      ],
    );
  }
}

class _OptionsList extends StatefulWidget {
  final Iterable<String> options;
  final ValueChanged<String> onSelected;

  /// The field the list hangs under.
  final GlobalKey fieldKey;

  const _OptionsList({
    required this.options,
    required this.onSelected,
    required this.fieldKey,
  });

  @override
  State<_OptionsList> createState() => _OptionsListState();
}

class _OptionsListState extends State<_OptionsList>
    with WidgetsBindingObserver {
  /// Tallest the list may be.
  static const double _maxHeight = 260;

  /// Never shorter than one row, however little room there is.
  static const double _minHeight = kMinInteractiveDimension;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The keyboard moved: measure again.
  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  /// The room between the bottom of the field and the top of the keyboard
  /// (or the bottom safe area). The overlay itself runs under the keyboard,
  /// so without this cap the lower rows sit behind it.
  ///
  /// The insets come from the view, not MediaQuery: this list inherits the
  /// field's MediaQuery, where a Scaffold has already zeroed the keyboard.
  double _heightFor(BuildContext context) {
    final box = widget.fieldKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return _maxHeight;
    final media = MediaQueryData.fromView(View.of(context));
    final fieldBottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    final visibleBottom = media.size.height -
        math.max(media.viewInsets.bottom, media.viewPadding.bottom);
    final room = visibleBottom - fieldBottom - AppSpacing.sm;
    return room.clamp(_minHeight, _maxHeight);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.options.toList();
    return Material(
      elevation: 4,
      borderRadius: AppRadii.rMd,
      color: AppColors.surface,
      child: ConstrainedBox(
        // 145 specialties would otherwise run off the screen, or behind the
        // keyboard.
        key: const ValueKey('specialty-options'),
        constraints: BoxConstraints(maxHeight: _heightFor(context)),
        child: ListView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: items.length,
          itemBuilder: (context, i) {
            final option = items[i];
            final isOther = option == Specialties.other;
            return Semantics(
              button: true,
              child: InkWell(
                onTap: () => widget.onSelected(option),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  child: Text(
                    isOther ? '$option…' : option,
                    style: isOther
                        ? AppText.bodyPrimary.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                          )
                        : AppText.bodyPrimary,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
