import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/chat_theme.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../core/utils/waveform.dart';
import '../../data/models/message.dart';
import '../../state/voice_playback_state.dart';
import 'app_pressable.dart';
import 'attachment_bubbles.dart';

/// Voice note (batch 5): the recorded waveform, drag-to-scrub, elapsed /
/// remaining time, a 1× / 1.5× / 2× pill, and auto-play of the next note
/// through [VoicePlayback]. Sending bubbles ([status] not sent) render the
/// same frame with a status tick and no player.
class VoiceNoteBubble extends ConsumerWidget {
  final String messageId;
  final String conversationId;
  final int durationSec;
  final String? transcript;
  final String? caption;
  final Uint8List? waveform;
  final bool isMine;
  final DateTime timestamp;
  final bool read;
  final bool delivered;
  final MessageStatus status;

  /// How to get the audio; null while the note is still local.
  final Future<({String path, bool isFile})> Function()? resolve;

  const VoiceNoteBubble({
    super.key,
    required this.messageId,
    required this.conversationId,
    required this.durationSec,
    required this.transcript,
    required this.isMine,
    required this.timestamp,
    this.caption,
    this.waveform,
    this.read = false,
    this.delivered = false,
    this.status = MessageStatus.sent,
    this.resolve,
  });

  static String format(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(voicePlaybackProvider);
    final radius = isMine ? AppRadii.bubbleSent : AppRadii.bubbleReceived;
    // Chat colour theme (batch 6), like MessageBubble: a hard-coded white
    // received bubble was unreadable under the dark palette.
    final chatTheme = ChatThemeScope.of(context);
    final bg = isMine ? chatTheme.sentBg : chatTheme.receivedBg;
    final contrast = isMine ? chatTheme.sentFg : AppColors.medBlue;
    final receivedBorder = chatTheme.receivedBorder;
    final current = playback.isCurrent(messageId);
    final playing = playback.isPlaying(messageId);
    final loading = playback.isLoading(messageId);
    final progress = playback.progressOf(messageId, durationSec);
    final total = current && playback.duration > Duration.zero
        ? playback.duration
        : Duration(seconds: durationSec);
    final position = playback.positionOf(messageId);
    // Elapsed while playing / scrubbed; the full length otherwise.
    final label = current && (playing || position > Duration.zero)
        ? '${format(position)} / ${format(total)}'
        : format(total);
    final canPlay = resolve != null && status == MessageStatus.sent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: radius,
            border: isMine || receivedBorder == null ? null : Border.all(color: receivedBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
                child: Row(
                  children: [
                    AppPressable(
                      key: ValueKey('voice-play-$messageId'),
                      onTap: canPlay && !loading
                          ? () => playback.toggle(messageId, conversationId, resolve!)
                          : null,
                      minTarget: true,
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: contrast.withValues(alpha: 0.22),
                          shape: BoxShape.circle,
                        ),
                        child: loading
                            ? Padding(
                                padding: const EdgeInsets.all(9),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(contrast),
                                ),
                              )
                            : Icon(
                                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                key: ValueKey(playing ? 'voice-pause-icon' : 'voice-play-icon'),
                                color: contrast,
                                size: 24,
                              ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: WaveformScrubber(
                        key: ValueKey('voice-wave-$messageId'),
                        bars: Waveform.bars(waveform, seed: messageId),
                        progress: progress,
                        color: contrast,
                        enabled: current,
                        onSeek: (f) => playback.seekFraction(messageId, f, durationSec),
                      ),
                    ),
                    if (current) ...[
                      const SizedBox(width: AppSpacing.sm),
                      AppPressable(
                        key: const ValueKey('voice-speed'),
                        onTap: playback.cycleSpeed,
                        minTarget: true,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
                          decoration: BoxDecoration(
                            color: contrast.withValues(alpha: 0.18),
                            borderRadius: AppRadii.rFull,
                          ),
                          child: Text(
                            _speedLabel(playback.speed),
                            style: AppText.badge.copyWith(color: contrast, fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md + 46, 0, AppSpacing.md, AppSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        key: ValueKey('voice-time-$messageId'),
                        style: AppText.timestamp.copyWith(color: contrast.withValues(alpha: 0.75)),
                      ),
                    ),
                    BubbleFooter(
                      isMine: isMine,
                      timestamp: timestamp,
                      read: read,
                      delivered: delivered,
                      status: status,
                    ),
                  ],
                ),
              ),
              if (caption != null && caption!.isNotEmpty)
                MediaCaption(text: caption!, isMine: isMine, padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm)),
              if (transcript != null && transcript!.isNotEmpty) ...[
                Container(height: 1, color: contrast.withValues(alpha: 0.15)),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Text(
                    transcript!,
                    style: AppText.timestamp.copyWith(
                      fontStyle: FontStyle.italic,
                      color: contrast.withValues(alpha: 0.75),
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _speedLabel(double s) => s == s.roundToDouble() ? '${s.round()}×' : '$s×';
}

/// The bars of a voice note with the played part tinted; drag (or tap) to
/// seek when [enabled].
class WaveformScrubber extends StatefulWidget {
  final List<double> bars;
  final double progress;
  final Color color;
  final bool enabled;
  final ValueChanged<double>? onSeek;
  final double height;

  const WaveformScrubber({
    super.key,
    required this.bars,
    required this.progress,
    required this.color,
    this.enabled = true,
    this.onSeek,
    this.height = 26,
  });

  @override
  State<WaveformScrubber> createState() => _WaveformScrubberState();
}

class _WaveformScrubberState extends State<WaveformScrubber> {
  double? _dragging;

  void _at(Offset local, double width) {
    final f = (local.dx / width).clamp(0.0, 1.0);
    setState(() => _dragging = f);
  }

  void _commit() {
    final f = _dragging;
    if (f != null) widget.onSeek?.call(f);
    setState(() => _dragging = null);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final progress = _dragging ?? widget.progress;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.enabled ? (d) => _at(d.localPosition, c.maxWidth) : null,
          onTapUp: widget.enabled ? (_) => _commit() : null,
          onHorizontalDragStart: widget.enabled ? (d) => _at(d.localPosition, c.maxWidth) : null,
          onHorizontalDragUpdate: widget.enabled ? (d) => _at(d.localPosition, c.maxWidth) : null,
          onHorizontalDragEnd: widget.enabled ? (_) => _commit() : null,
          onHorizontalDragCancel: widget.enabled ? () => setState(() => _dragging = null) : null,
          child: CustomPaint(
            size: Size(c.maxWidth, widget.height),
            painter: _WavePainter(bars: widget.bars, progress: progress, color: widget.color),
          ),
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  final List<double> bars;
  final double progress;
  final Color color;
  _WavePainter({required this.bars, required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final gap = 2.0;
    final w = (size.width - gap * (bars.length - 1)) / bars.length;
    final played = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = w.clamp(1.5, 4.0);
    final rest = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = played.strokeWidth;
    final cutoff = progress * bars.length;
    for (var i = 0; i < bars.length; i++) {
      final x = i * (w + gap) + w / 2;
      final h = (bars[i] * size.height).clamp(2.0, size.height);
      final y0 = (size.height - h) / 2;
      canvas.drawLine(Offset(x, y0), Offset(x, y0 + h), i < cutoff ? played : rest);
    }
    // Playhead.
    if (progress > 0) {
      final px = (progress * size.width).clamp(0.0, size.width);
      canvas.drawCircle(Offset(px, size.height / 2), 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.progress != progress || old.bars != bars || old.color != color;
}
