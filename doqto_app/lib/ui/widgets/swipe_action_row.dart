import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';

/// One button revealed behind a swiped row.
class SwipeAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final Key? key;

  const SwipeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.key,
  });
}

/// Horizontal-drag row with a button behind each edge (no plugin): drag left
/// reveals [trailing] on the right, drag right reveals [leading] on the left.
/// The row snaps open past half an action width and snaps shut otherwise; a
/// tap on the open row or on an action closes it. Vertical scrolling is left
/// to the list — only horizontal drags are claimed.
class SwipeActionRow extends StatefulWidget {
  final Widget child;
  final SwipeAction? leading;
  final SwipeAction? trailing;
  final bool enabled;

  static const double actionWidth = 88;

  const SwipeActionRow({
    super.key,
    required this.child,
    this.leading,
    this.trailing,
    this.enabled = true,
  });

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  double _offset = 0; // + = leading revealed, - = trailing revealed
  Animation<double>? _snap;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: AppMotion.micro);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double get _maxLeft => widget.trailing == null ? 0 : SwipeActionRow.actionWidth;
  double get _maxRight => widget.leading == null ? 0 : SwipeActionRow.actionWidth;

  void _onUpdate(DragUpdateDetails d) {
    if (!widget.enabled) return;
    _ctrl.stop();
    _snap = null;
    setState(() {
      _offset = (_offset + d.delta.dx).clamp(-_maxLeft, _maxRight);
    });
  }

  void _onEnd(DragEndDetails d) {
    if (!widget.enabled) return;
    final v = d.primaryVelocity ?? 0;
    double target = 0;
    if (_offset < 0 && (_offset < -_maxLeft / 2 || v < -300)) target = -_maxLeft;
    if (_offset > 0 && (_offset > _maxRight / 2 || v > 300)) target = _maxRight;
    _animateTo(target);
  }

  void _animateTo(double target) {
    if (_offset == target) return;
    final reduced = AppMotion.reduced(context);
    if (reduced) {
      setState(() => _offset = target);
      return;
    }
    final anim = Tween<double>(begin: _offset, end: target).animate(
      CurvedAnimation(parent: _ctrl, curve: AppMotion.standard),
    );
    _snap = anim;
    void tick() {
      if (!mounted || _snap != anim) return;
      setState(() => _offset = anim.value);
    }
    anim.addListener(tick);
    _ctrl.forward(from: 0).whenComplete(() => anim.removeListener(tick));
  }

  void close() => _animateTo(0);

  bool get _open => _offset != 0;

  @override
  Widget build(BuildContext context) {
    final leading = widget.leading;
    final trailing = widget.trailing;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: widget.enabled ? _onUpdate : null,
      onHorizontalDragEnd: widget.enabled ? _onEnd : null,
      child: Stack(
        children: [
          if (leading != null)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _ActionButton(
                  action: leading,
                  visible: _offset > 0,
                  onTap: () {
                    close();
                    leading.onTap();
                  },
                ),
              ),
            ),
          if (trailing != null)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: _ActionButton(
                  action: trailing,
                  visible: _offset < 0,
                  onTap: () {
                    close();
                    trailing.onTap();
                  },
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_offset, 0),
            child: Container(
              color: AppColors.surface,
              child: _open
                  // Open: the first tap only closes the row.
                  ? AbsorbPointer(
                      child: GestureDetector(onTap: close, child: widget.child),
                    )
                  : widget.child,
            ),
          ),
          if (_open)
            Positioned.fill(
              left: _offset > 0 ? _offset : 0,
              right: _offset < 0 ? -_offset : 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: close,
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final SwipeAction action;
  final bool visible;
  final VoidCallback onTap;
  const _ActionButton({
    required this.action,
    required this.visible,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: SwipeActionRow.actionWidth,
      height: double.infinity,
      child: Material(
        color: action.color,
        child: InkWell(
          key: action.key,
          onTap: visible ? onTap : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(action.icon, color: AppColors.white, size: 22),
              const SizedBox(height: AppSpacing.xs),
              Text(
                action.label,
                style: AppText.badge.copyWith(color: AppColors.white, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
