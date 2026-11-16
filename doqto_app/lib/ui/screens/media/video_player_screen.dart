import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../widgets/app_pressable.dart';

/// Full-screen video with play / pause, a scrub bar and elapsed / total
/// time (batch 5 C). Plays a cached file when the clip is on the phone,
/// otherwise streams the presigned URL.
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
    _init();
  }

  Future<void> _init() async {
    try {
      final c = widget.file != null
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
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
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
        onTap: () => setState(() => _showChrome = !_showChrome),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (c != null)
              Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)))
            else if (_failed)
              const Center(child: Icon(Icons.error_outline_rounded, color: AppColors.white, size: 40))
            else
              const Center(child: CircularProgressIndicator(color: AppColors.white)),
            if (c != null && !playing)
              Center(
                child: AppPressable(
                  key: const ValueKey('video-play-big'),
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
                          IconButton(
                            key: const ValueKey('video-close'),
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close, color: AppColors.white),
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
                              Padding(
                                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
                                child: Text(widget.caption!, style: AppText.body.copyWith(color: AppColors.white)),
                              ),
                            Row(
                              children: [
                                IconButton(
                                  key: const ValueKey('video-toggle'),
                                  onPressed: c == null ? null : () => playing ? c.pause() : c.play(),
                                  icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: AppColors.white),
                                ),
                                Text(_fmt(pos), key: const ValueKey('video-position'), style: AppText.timestamp.copyWith(color: AppColors.white)),
                                Expanded(
                                  child: Slider(
                                    key: const ValueKey('video-scrub'),
                                    value: total.inMilliseconds == 0 ? 0 : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0),
                                    activeColor: AppColors.white,
                                    inactiveColor: AppColors.white.withValues(alpha: 0.3),
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
