import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/error_messages.dart';
import 'primary_button.dart';

/// The visual for one state value of a [StatefulActionButton].
class ActionVisual {
  final String label;
  final IconData? icon;
  final AppButtonVariant variant;

  const ActionVisual({
    required this.label,
    this.icon,
    this.variant = AppButtonVariant.primary,
  });
}

/// A button whose look is driven by a state value [S]. On tap it:
///   1. optimistically flips to `optimisticNext(state)` (if provided),
///   2. shows a width-stable label↔spinner crossfade (reuses [AppButton]),
///   3. runs [onPressed], and
///   4. rolls the optimistic flip back, fires an error haptic and says what
///      went wrong if it throws.
///
/// The real state is owned upstream (e.g. a Riverpod notifier that also flips
/// optimistically and rolls back on error); the local optimism just keeps the
/// button label in lockstep with the tap even before the parent rebuilds.
class StatefulActionButton<S> extends StatefulWidget {
  final S state;
  final Map<S, ActionVisual> visuals;
  final Future<void> Function() onPressed;
  final S Function(S)? optimisticNext;
  final bool expand;

  const StatefulActionButton({
    super.key,
    required this.state,
    required this.visuals,
    required this.onPressed,
    this.optimisticNext,
    this.expand = false,
  });

  @override
  State<StatefulActionButton<S>> createState() =>
      _StatefulActionButtonState<S>();
}

class _StatefulActionButtonState<S> extends State<StatefulActionButton<S>> {
  bool _loading = false;
  S? _optimistic;

  S get _effectiveState => _optimistic ?? widget.state;

  @override
  void didUpdateWidget(StatefulActionButton<S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Once the parent's real state catches up to our optimistic guess, drop the
    // local override so we follow the source of truth again.
    if (_optimistic != null && widget.state == _optimistic) {
      _optimistic = null;
    }
  }

  Future<void> _handleTap() async {
    if (_loading) return;
    setState(() {
      _optimistic = widget.optimisticNext?.call(widget.state);
      _loading = true;
    });
    try {
      await widget.onPressed();
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      HapticFeedback.heavyImpact();
      if (!mounted) return;
      setState(() {
        _optimistic = null; // roll back to the real state
        _loading = false;
      });
      // The label snapping back is easy to miss and says nothing about why.
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visual = widget.visuals[_effectiveState] ??
        widget.visuals.values.first;
    return AppButton(
      label: visual.label,
      icon: visual.icon,
      variant: visual.variant,
      loading: _loading,
      expand: widget.expand,
      onPressed: _handleTap,
    );
  }
}
