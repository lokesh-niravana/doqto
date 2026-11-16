import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/constants/strings.dart';
import '../../core/chat_theme.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../data/models/message.dart';
import 'quote_strip.dart';

/// Status tick shown on own messages: clock (sending) → check (sent) →
/// gray double-check (delivered) → blue double-check (read) → red ! (failed).
class MessageStatusTick extends StatelessWidget {
  final MessageStatus status;
  final bool delivered;
  final bool read;
  final Color idleColor;
  const MessageStatusTick({
    super.key,
    required this.status,
    required this.read,
    required this.idleColor,
    this.delivered = false,
  });

  @override
  Widget build(BuildContext context) {
    final icon = switch (status) {
      MessageStatus.sending => _PulsingClock(
        key: const ValueKey('tick-sending'),
        color: idleColor,
      ),
      MessageStatus.failed => const Icon(
        Icons.error_outline,
        key: ValueKey('tick-failed'),
        size: 15,
        color: Color(0xFFFFB4A9),
      ),
      MessageStatus.sent => Icon(
        (read || delivered) ? Icons.done_all : Icons.check,
        key: ValueKey(
          'tick-sent-${read
              ? 'read'
              : delivered
              ? 'delivered'
              : 'sent'}',
        ),
        size: 15,
        color: read ? const Color(0xFF7FC8FF) : idleColor,
      ),
    };
    return AnimatedSwitcher(
      duration: AppMotion.maybe(context, AppMotion.micro),
      switchInCurve: AppMotion.curveEnter,
      switchOutCurve: AppMotion.curveExit,
      child: icon,
    );
  }
}

/// Clock icon with a gentle opacity pulse while a message is pending.
/// Reduced-motion aware (static icon when animations are disabled).
class _PulsingClock extends StatefulWidget {
  final Color color;
  const _PulsingClock({super.key, required this.color});

  @override
  State<_PulsingClock> createState() => _PulsingClockState();
}

class _PulsingClockState extends State<_PulsingClock>
    with SingleTickerProviderStateMixin {
  static const Duration _period = Duration(milliseconds: 900);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _period,
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 1.0,
    end: 0.45,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _controller.stop();
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Icon(Icons.schedule, size: 13, color: widget.color),
    );
  }
}

/// Centered pill for in-chat system banners (e.g. disappearing-messages
/// changes). No timestamp, no read ticks.
class SystemMessageBubble extends StatelessWidget {
  final String text;
  const SystemMessageBubble({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      child: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.8,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs + 2,
          ),
          decoration: BoxDecoration(
            color: AppColors.gray100,
            borderRadius: AppRadii.rFull,
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: AppText.timestamp.copyWith(color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final String text;
  final bool isMine;
  final DateTime timestamp;
  final String? senderName;
  final int senderColorIndex;
  final bool read;
  final bool delivered;
  final MessageStatus status;

  /// True when the bubble visually above is from the same sender on the same
  /// day — tightens vertical spacing so runs read as one group.
  final bool grouped;

  /// Sender deleted it: WhatsApp-style tombstone, no ticks, [text] ignored.
  final bool deleted;

  /// Sender edited it: "Edited" label next to the time; tap opens history.
  final bool edited;
  final VoidCallback? onEditedTap;

  // Batch 4 ------------------------------------------------------------------
  /// Rich body (formatting, mentions, links). When null, [text] renders plain.
  final Widget? body;

  /// The quoted message, shown above the body; tap jumps to it.
  final ReplyPreview? quote;
  final String? quoteSenderName;
  final VoidCallback? onQuoteTap;
  final String? Function(String userId)? nameFor;

  /// "Forwarded" / "Forwarded many times" above the body.
  final String? forwardedLabel;

  /// Starred by me: small star next to the time.
  final bool starred;

  /// Under the body (a link preview card).
  final Widget? footer;

  /// Search hit / jump target: tinted outline that fades.
  final bool highlighted;

  const MessageBubble({
    super.key,
    required this.text,
    required this.isMine,
    required this.timestamp,
    this.senderName,
    this.senderColorIndex = 0,
    this.read = false,
    this.delivered = false,
    this.status = MessageStatus.sent,
    this.grouped = false,
    this.deleted = false,
    this.edited = false,
    this.onEditedTap,
    this.body,
    this.quote,
    this.quoteSenderName,
    this.onQuoteTap,
    this.nameFor,
    this.forwardedLabel,
    this.starred = false,
    this.footer,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = isMine ? AppRadii.bubbleSent : AppRadii.bubbleReceived;
    // Chat colour theme (batch 6): the thread's ChatThemeScope, else brand.
    final chatTheme = ChatThemeScope.of(context);
    final bg = isMine ? chatTheme.sentBg : chatTheme.receivedBg;
    final fg = isMine ? chatTheme.sentFg : chatTheme.receivedFg;
    final timeColor = isMine
        ? fg.withValues(alpha: 0.55)
        : AppColors.textMuted;
    final muted = isMine
        ? fg.withValues(alpha: 0.7)
        : AppColors.textMuted;

    Widget bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.72,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        border: highlighted
            ? Border.all(color: AppColors.amber, width: 2)
            : isMine
                ? null
                : (chatTheme.receivedBorder == null
                    ? null
                    : Border.all(color: chatTheme.receivedBorder!)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (forwardedLabel != null && !deleted)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                key: const ValueKey('forwarded-label'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shortcut_rounded, size: 13, color: muted),
                  const SizedBox(width: 3),
                  Text(
                    forwardedLabel!,
                    style: AppText.timestamp.copyWith(color: muted, fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
          if (quote != null && !deleted)
            QuoteStrip(
              quote: quote,
              senderName: quoteSenderName ?? '',
              isMine: isMine,
              onTap: onQuoteTap,
              nameFor: nameFor,
            ),
          if (senderName != null && !isMine)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                senderName!,
                style: AppText.timestamp.copyWith(
                  color: AppColors.avatarColorFor(senderColorIndex),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (deleted)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.block, size: 14, color: muted),
                const SizedBox(width: 4),
                Text(
                  Strings.chatMessageDeleted,
                  style: AppText.messageBody.copyWith(
                    color: muted,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            )
          else
            body ?? Text(text, style: AppText.messageBody.copyWith(color: fg)),
          if (footer != null && !deleted) footer!,
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.bottomRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (edited && !deleted) ...[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onEditedTap,
                    child: Text(
                      Strings.chatEdited,
                      style: AppText.timestamp.copyWith(
                        color: timeColor,
                        decoration: TextDecoration.underline,
                        decorationColor: timeColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                if (starred && !deleted) ...[
                  Icon(
                    Icons.star_rounded,
                    key: const ValueKey('bubble-star'),
                    size: 13,
                    color: timeColor,
                  ),
                  const SizedBox(width: 3),
                ],
                Text(
                  DateFormat.jm().format(timestamp),
                  style: AppText.timestamp.copyWith(color: timeColor),
                ),
                if (isMine && !deleted) ...[
                  const SizedBox(width: 3),
                  MessageStatusTick(
                    status: status,
                    read: read,
                    delivered: delivered,
                    idleColor: AppColors.white.withValues(alpha: 0.55),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    // Failed sends draw attention with a single, subtle horizontal shake.
    if (status == MessageStatus.failed) {
      bubble = _ShakeOnce(child: bubble);
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        grouped ? 1 : AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Row(
        mainAxisAlignment: isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [bubble],
      ),
    );
  }
}

/// One-shot horizontal shake played when a bubble first appears in the
/// failed state. Reduced-motion aware (renders statically when disabled).
class _ShakeOnce extends StatefulWidget {
  final Widget child;
  const _ShakeOnce({required this.child});

  @override
  State<_ShakeOnce> createState() => _ShakeOnceState();
}

class _ShakeOnceState extends State<_ShakeOnce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.emphasizedDuration,
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (AppMotion.reduced(context)) {
      _controller.value = 1.0;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isCompleted) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        // Damped sine: three swings fading out, max 4px.
        final dx = math.sin(t * math.pi * 6) * 4 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: widget.child,
    );
  }
}
