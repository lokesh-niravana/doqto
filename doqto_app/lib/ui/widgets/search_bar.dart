import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';

class AppSearchBar extends StatefulWidget {
  final ValueChanged<String> onChanged;
  final String hint;
  final Duration debounce;

  /// Text already in the box when it opens (not reported via [onChanged]).
  final String? initialValue;

  const AppSearchBar({
    super.key,
    required this.onChanged,
    this.initialValue,
    this.hint = 'Search…',
    this.debounce = const Duration(milliseconds: 200),
  });

  @override
  State<AppSearchBar> createState() => _AppSearchBarState();
}

class _AppSearchBarState extends State<AppSearchBar> {
  late final _controller = TextEditingController(text: widget.initialValue);
  final _focus = FocusNode();
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

  void _onChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.debounce, () {
      widget.onChanged(value.trim());
    });
    setState(() {});
  }

  void _clear() {
    _controller.clear();
    _debounceTimer?.cancel();
    widget.onChanged('');
    _focus.unfocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _controller.text.isNotEmpty;
    final focused = _focus.hasFocus;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenHorizontal,
        AppSpacing.sm,
        AppSpacing.screenHorizontal,
        AppSpacing.sm,
      ),
      child: AnimatedContainer(
        duration: AppMotion.maybe(context, AppMotion.micro),
        curve: AppMotion.standard,
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: AppRadii.rFull,
          border: Border.all(
            color: focused ? AppColors.medBlue : AppColors.gray100,
            width: focused ? 1.5 : 1.0,
          ),
        ),
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          onChanged: _onChanged,
          onTapOutside: (_) => _focus.unfocus(),
          style: AppText.bodyPrimary,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: widget.hint,
            hintStyle: AppText.body.copyWith(color: AppColors.textMuted),
            filled: false,
            prefixIcon: Icon(
              Icons.search,
              color: focused ? AppColors.medBlue : AppColors.textMuted,
              size: 20,
            ),
            suffixIcon: hasText
                ? IconButton(
                    icon: Icon(Icons.close, color: AppColors.textMuted, size: 20),
                    onPressed: _clear,
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm + 2,
            ),
            border: OutlineInputBorder(
              borderRadius: AppRadii.rFull,
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: AppRadii.rFull,
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: AppRadii.rFull,
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}
