import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';

/// WhatsApp's swipe-right-to-reply (batch 4): the row follows the finger up
/// to [maxDrag], a reply arrow fades in behind it, and releasing past
/// [threshold] fires [onReply]. The row always springs back. Only horizontal
/// drags are claimed, so the list keeps scrolling.
class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback? onReply;
  final bool enabled;

  static const double maxDrag = 72;
  static const double threshold = 48;

  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
  });

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> with SingleTickerProviderStateMixin {
  // Created eagerly: a lazy controller first touched in dispose() would look
  // up TickerMode on a deactivated element.
  late final AnimationController _ctrl;
  double _dx = 0;
  bool _armed = false;

  bool get _active => widget.enabled && widget.onReply != null;

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

  void _update(DragUpdateDetails d) {
    if (!_active) return;
    final next = (_dx + d.delta.dx).clamp(0.0, SwipeToReply.maxDrag);
    final armed = next >= SwipeToReply.threshold;
    if (armed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _dx = next;
      _armed = armed;
    });
  }

  void _end(DragEndDetails d) {
    if (!_active) return;
    final fire = _dx >= SwipeToReply.threshold;
    _springBack();
    if (fire) widget.onReply!();
  }

  void _springBack() {
    if (_dx == 0) return;
    if (AppMotion.reduced(context)) {
      setState(() {
        _dx = 0;
        _armed = false;
      });
      return;
    }
    final anim = Tween<double>(begin: _dx, end: 0).animate(
      CurvedAnimation(parent: _ctrl, curve: AppMotion.standard),
    );
    void tick() {
      if (!mounted) return;
      setState(() => _dx = anim.value);
    }
    anim.addListener(tick);
    _ctrl.forward(from: 0).whenComplete(() {
      anim.removeListener(tick);
      if (mounted) setState(() => _armed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return widget.child;
    final t = (_dx / SwipeToReply.threshold).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _springBack,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (_dx > 0)
            Positioned(
              left: 12,
              child: Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: 0.6 + 0.4 * t,
                  child: Container(
                    key: const ValueKey('swipe-reply-icon'),
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: _armed ? AppColors.medBlue : AppColors.gray200,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.reply_rounded,
                      size: 18,
                      color: _armed ? AppColors.white : AppColors.gray600,
                    ),
                  ),
                ),
              ),
            ),
          Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ],
      ),
    );
  }
}
