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
/// double-check (delivered) → filled check disc, blue (read) → red ! (failed).
/// Read and delivered differ by glyph as well as tint.
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
        color: _failedTick,
      ),
      MessageStatus.sent => Icon(
        // Three shapes, not two shapes and a tint: one check (sent), two
        // checks (delivered), a filled disc with a check (read).
        read
            ? Icons.check_circle
            : delivered
            ? Icons.done_all
            : Icons.check,
        key: ValueKey(
          'tick-sent-${read
              ? 'read'
              : delivered
              ? 'delivered'
              : 'sent'}',
        ),
        size: 15,
        color: read ? _readTick : idleColor,
      ),
    };
    // The tick is the only place delivery state shows: say it, don't just
    // draw it.
    final label = switch (status) {
      MessageStatus.sending => Strings.tickSending,
      MessageStatus.failed => Strings.tickFailed,
      MessageStatus.sent => read
          ? Strings.tickRead
          : delivered
              ? Strings.tickDelivered
              : Strings.tickSent,
    };
    return Semantics(
      label: label,
      child: AnimatedSwitcher(
        duration: AppMotion.maybe(context, AppMotion.micro),
        switchInCurve: AppMotion.curveEnter,
        switchOutCurve: AppMotion.curveExit,
        child: icon,
      ),
    );
  }
}

/// Tick tints on a sent bubble. An icon needs 3:1 against what it sits on;
/// the lowest of the twelve chat themes is Ocean (#1D6ECF), where these are
/// 3.61:1 (failed) and 3.65:1 (read). The earlier, more saturated pair was
/// 2.95 and 2.77 there.
const Color _failedTick = Color(0xFFFFD0C9);
const Color _readTick = Color(0xFFB9E1FF);

/// Alpha for secondary text (time, "Edited", labels, ticks) on a sent
/// bubble: anything lower drops under 4.5:1 on the bubble colours.
const double kOnSentSecondaryAlpha = 0.93;

/// Fill for an inset inside a sent bubble (quote, link card, code block,
/// mention chip, speed pill). It darkens the bubble: white text on it is
/// 6.8:1 or better on every chat theme, where the old white tint lightened
/// the bubble to about 3.6:1.
const Color kOnSentInset = Color(0x2E000000); // black at 18%

/// Group sender names borrow the avatar colour, but some of those fills are
/// too light for 11pt text on a light bubble: bright teal and amber are
/// about 2:1, brand teal 4.41:1 on the Plum received bubble. Swap them for
/// their text-safe variants (badge teal is 5.58:1 at worst, purple text
/// 7.64:1).
Color senderNameColor(int index) {
  final c = AppColors.avatarColorFor(index);
  if (c == AppColors.medTeal || c == AppColors.medBlue) return AppColors.tealBadgeText;
  if (c == AppColors.purple) return AppColors.purpleText;
  if (c == AppColors.amber) return AppColors.amberText;
  return c;
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

  /// Vertical padding inside the bubble.
  static const double _padV = AppSpacing.sm + 2;

  @override
  Widget build(BuildContext context) {
    final radius = isMine ? AppRadii.bubbleSent : AppRadii.bubbleReceived;
    // Chat colour theme (batch 6): the thread's ChatThemeScope, else brand.
    final chatTheme = ChatThemeScope.of(context);
    final bg = isMine ? chatTheme.sentBg : chatTheme.receivedBg;
    final fg = isMine ? chatTheme.sentFg : chatTheme.receivedFg;
    final timeColor = isMine
        ? fg.withValues(alpha: kOnSentSecondaryAlpha)
        : AppColors.textMuted;
    final muted = isMine
        ? fg.withValues(alpha: kOnSentSecondaryAlpha)
        : AppColors.textMuted;
    // Ties the small "Edited" label to its 44pt tap area (see below).
    final editedLink = LayerLink();
    final editedTappable = edited && !deleted && onEditedTap != null;

    Widget bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.72,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: _padV,
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
                  Flexible(
                    child: Text(
                      forwardedLabel!,
                      style: AppText.timestamp.copyWith(color: muted, fontStyle: FontStyle.italic),
                    ),
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
                  color: senderNameColor(senderColorIndex),
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
                Flexible(
                  child: Text(
                    Strings.chatMessageDeleted,
                    style: AppText.messageBody.copyWith(
                      color: muted,
                      fontStyle: FontStyle.italic,
                    ),
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
                  CompositedTransformTarget(
                    link: editedLink,
                    child: Semantics(
                      button: onEditedTap != null,
                      label: onEditedTap != null
                          ? Strings.chatEditedShowHistory
                          : null,
                      excludeSemantics: onEditedTap != null,
                      child: GestureDetector(
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
                    semanticLabel: Strings.a11yStarred,
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
                    idleColor: timeColor,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    // The "Edited" link is one line of 11pt text. Its tap area is a 44pt
    // square laid over the bubble's bottom edge and following the label, so
    // the target is finger-sized without the footer row growing.
    if (editedTappable) {
      bubble = Stack(
        children: [
          bubble,
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: editedLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomCenter,
              followerAnchor: Alignment.bottomCenter,
              offset: const Offset(0, _padV),
              child: ExcludeSemantics(
                child: GestureDetector(
                  key: const ValueKey('edited-tap-area'),
                  behavior: HitTestBehavior.translucent,
                  onTap: onEditedTap,
                  child: const SizedBox(width: 44, height: 44),
                ),
              ),
            ),
          ),
        ],
      );
    }

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
