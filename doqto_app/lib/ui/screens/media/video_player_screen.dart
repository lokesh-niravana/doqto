import '../../../core/utils/app_orientation.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/constants/strings.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/media_load_failed.dart';

/// Full-screen video with play / pause, a scrub bar and elapsed / total
/// time (batch 5 C). Plays a cached file when the clip is on the phone,
/// otherwise streams the presigned URL.
const _closeLabel = 'Close';
const _playLabel = 'Play';
const _pauseLabel = 'Pause';

class VideoPlayerScreen extends StatefulWidget {
  final File? file;
  final Future<String> Function()? resolveUrl;
  final String? caption;

  const VideoPlayerScreen({super.key, this.file, this.resolveUrl, this.caption})
      : assert(file != null || resolveUrl != null);

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _controller;
  bool _failed = false;
  bool _showChrome = true;
  double? _scrubbing;

  @override
  void initState() {
    super.initState();
    AppOrientation.enterMedia();
    _init();
  }

  /// Also the "Try again" action after a failure.
  Future<void> _init() async {
    if (_failed) setState(() => _failed = false);
    VideoPlayerController? c;
    try {
      c = widget.file != null
          ? VideoPlayerController.file(widget.file!)
          : VideoPlayerController.networkUrl(Uri.parse(await widget.resolveUrl!()));
      await c.initialize();
      c.addListener(_onTick);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
      await c.play();
    } catch (_) {
      // A controller that never initialised is not kept, so a retry starts clean.
      if (_controller == null) {
        c?.removeListener(_onTick);
        try {
          await c?.dispose();
        } catch (_) {}
      }
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppOrientation.leaveMedia();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  static String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final playing = c?.value.isPlaying ?? false;
    final total = c?.value.duration ?? Duration.zero;
    final pos = _scrubbing != null
        ? total * _scrubbing!
        : (c?.value.position ?? Duration.zero);
    return Scaffold(
      backgroundColor: AppColors.gray900,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Only shows or hides the controls; the video itself carries the name.
        excludeFromSemantics: true,
        onTap: () => setState(() => _showChrome = !_showChrome),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (c != null)
              Center(
                child: Semantics(
                  image: true,
                  label: Strings.mediaVideo,
                  child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
                ),
              )
            else if (_failed)
              MediaLoadFailed(
                key: const ValueKey('video-failed'),
                message: Strings.mediaVideoLoadFailed,
                onRetry: _init,
              )
            else
              const Center(
                child: CircularProgressIndicator(color: AppColors.white, semanticsLabel: Strings.loading),
              ),
            if (c != null && !playing)
              Center(
                child: AppPressable(
                  key: const ValueKey('video-play-big'),
                  semanticLabel: _playLabel,
                  onTap: () => c.play(),
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(color: AppColors.gray900.withValues(alpha: 0.6), shape: BoxShape.circle),
                    child: const Icon(Icons.play_arrow_rounded, color: AppColors.white, size: 40),
                  ),
                ),
              ),
            AnimatedOpacity(
              opacity: _showChrome ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: IgnorePointer(
                ignoring: !_showChrome,
                child: Column(
                  children: [
                    SafeArea(
                      bottom: false,
                      child: Row(
                        children: [
                          // A white glyph vanishes on a bright frame; the dark
                          // disc (as in the photo viewer) keeps it at 4.7:1
                          // even over pure white.
                          Padding(
                            padding: const EdgeInsets.all(4),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: AppColors.gray900.withValues(alpha: 0.6),
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                key: const ValueKey('video-close'),
                                tooltip: _closeLabel,
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close, color: AppColors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Container(
                      color: AppColors.gray900.withValues(alpha: 0.6),
                      child: SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.caption != null && widget.caption!.isNotEmpty)
                              // A long caption scrolls in at most 30% of the
                              // screen instead of pushing the controls off it.
                              ConstrainedBox(
                                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
                                  child: Text(widget.caption!, style: AppText.body.copyWith(color: AppColors.white)),
                                ),
                              ),
                            Row(
                              children: [
                                IconButton(
                                  key: const ValueKey('video-toggle'),
                                  tooltip: playing ? _pauseLabel : _playLabel,
                                  onPressed: c == null ? null : () => playing ? c.pause() : c.play(),
                                  icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: AppColors.white),
                                ),
                                Text(_fmt(pos), key: const ValueKey('video-position'), style: AppText.timestamp.copyWith(color: AppColors.white)),
                                Expanded(
                                  child: Semantics(
                                    label: Strings.videoPositionLabel,
                                    child: Slider(
                                      key: const ValueKey('video-scrub'),
                                      value: total.inMilliseconds == 0 ? 0 : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0),
                                      activeColor: AppColors.white,
                                      inactiveColor: AppColors.white.withValues(alpha: 0.3),
                                      // "0:12 of 1:05", not "18%".
                                      semanticFormatterCallback: (v) =>
                                          Strings.voicePositionValue(_fmt(total * v), _fmt(total)),
                                      onChangeStart: c == null ? null : (v) => setState(() => _scrubbing = v),
                                      onChanged: c == null ? null : (v) => setState(() => _scrubbing = v),
                                      onChangeEnd: c == null
                                          ? null
                                          : (v) async {
                                              await c.seekTo(total * v);
                                              if (mounted) setState(() => _scrubbing = null);
                                            },
                                    ),
                                  ),
                                ),
                                Text(_fmt(total), style: AppText.timestamp.copyWith(color: AppColors.white)),
                                const SizedBox(width: AppSpacing.md),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
