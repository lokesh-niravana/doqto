import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../../state/chat_state.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/motion.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';
import '../../../state/settings_state.dart';

enum _RecorderState { recording, recorded, sending }

class VoiceRecorderPanel extends ConsumerStatefulWidget {
  final String conversationId;
  final VoidCallback onSent;
  final VoidCallback onCancel;

  const VoiceRecorderPanel({
    super.key,
    required this.conversationId,
    required this.onSent,
    required this.onCancel,
  });

  @override
  ConsumerState<VoiceRecorderPanel> createState() => _VoiceRecorderPanelState();
}

class _VoiceRecorderPanelState extends ConsumerState<VoiceRecorderPanel> {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _stt = SpeechToText();

  _RecorderState _state = _RecorderState.recording;
  final List<double> _amplitudes = [];
  String _transcript = '';
  String? _filePath;
  int _durationSec = 0;
  Timer? _timer;
  Timer? _ampTimer;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _startRecording();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ampTimer?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (!mounted) return;
      final shouldOpen = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Microphone access needed'),
          content: const Text(
            'Doqto needs microphone permission to record voice notes. '
            'Tap "Open Settings" to enable it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      if (shouldOpen == true) {
        await openAppSettings();
      }
      if (mounted) widget.onCancel();
      return;
    }

    // Live transcript can be switched off (batch 6, Settings → Chats).
    final transcribe = ref.read(appSettingsProvider).voiceTranscript;
    if (transcribe) await _stt.initialize();

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';

    await _recorder.start(
      RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: path,
    );

    if (transcribe) {
      _stt.listen(
        onResult: (result) {
          if (mounted) setState(() => _transcript = result.recognizedWords);
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
        ),
      );
    }

    final stopwatch = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _durationSec = stopwatch.elapsed.inSeconds);
    });

    _ampTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final amp = await _recorder.getAmplitude();
      if (!mounted) return;
      final normalized = ((amp.current + 60) / 60).clamp(0.05, 1.0);
      setState(() {
        _amplitudes.add(normalized);
        if (_amplitudes.length > 40) _amplitudes.removeAt(0);
      });
    });
  }

  Future<void> _stopRecording() async {
    _timer?.cancel();
    _ampTimer?.cancel();
    _stt.stop();
    final path = await _recorder.stop();
    if (!mounted) return;
    setState(() {
      _filePath = path;
      _state = _RecorderState.recorded;
    });
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.pause();
      setState(() => _isPlaying = false);
    } else {
      if (_player.processingState == ProcessingState.completed ||
          _player.processingState == ProcessingState.idle) {
        await _player.setFilePath(_filePath!);
      }
      _player.play();
      setState(() => _isPlaying = true);
      _player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed && mounted) {
          setState(() => _isPlaying = false);
        }
      });
    }
  }

  /// Outbox-first: sendVoice copies the recording to durable storage,
  /// enqueues, and shows an optimistic bubble — the panel dismisses
  /// immediately; delivery failures surface as a failed bubble (tap to retry).
  Future<void> _send() async {
    if (_filePath == null) return;
    setState(() => _state = _RecorderState.sending);
    try {
      await ref.read(messagesProvider(widget.conversationId).notifier).sendVoice(
            sourcePath: _filePath!,
            durationSec: _durationSec,
            transcript: _transcript.isNotEmpty ? _transcript : null,
          );
      // M8: the outbox persisted its own durable copy — drop the temp .wav.
      try {
        await File(_filePath!).delete();
      } catch (_) {}
      if (!mounted) return;
      widget.onSent();
    } catch (e) {
      // Only local persistence can throw (e.g. disk full).
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
      setState(() => _state = _RecorderState.recorded);
    }
  }

  void _discard() {
    if (_filePath != null) {
      File(_filePath!).delete().catchError((_) => File(_filePath!));
    }
    widget.onCancel();
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // FadeSlideIn gives the panel a one-shot slide-up + fade entrance
    // (reduced-motion aware); recording logic is untouched.
    return FadeSlideIn(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          top: false,
          child: _state == _RecorderState.recording
              ? _buildRecording()
              : _buildRecorded(),
        ),
      ),
    );
  }

  Widget _buildRecording() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 44,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 40; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    curve: Curves.easeOut,
                    width: 3,
                    height: i < _amplitudes.length
                        ? (_amplitudes[i] * 40).clamp(2.0, 40.0)
                        : 2.0,
                    decoration: BoxDecoration(
                      color: AppColors.medBlue,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_transcript.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text(
              _transcript,
              style: AppText.caption.copyWith(fontStyle: FontStyle.italic),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _RecPulseDot(),
                const SizedBox(width: AppSpacing.sm - 2),
                Text(_formatDuration(_durationSec), style: AppText.subheading),
              ],
            ),
            Material(
              color: AppColors.medBlue,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _stopRecording,
                child: Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  child: const Icon(Icons.stop, color: AppColors.white, size: 28),
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                _stopRecording().then((_) => _discard());
              },
              child: Text('Cancel', style: AppText.body.copyWith(color: AppColors.red)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRecorded() {
    final isSending = _state == _RecorderState.sending;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: isSending ? null : _togglePlay,
              icon: Icon(
                _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                color: AppColors.medBlue,
                size: 36,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: SizedBox(
                height: 32,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < _amplitudes.length && i < 40; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Container(
                          width: 3,
                          height: (_amplitudes[i] * 28).clamp(3.0, 28.0),
                          decoration: BoxDecoration(
                            color: AppColors.medBlue.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(1.5),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(_formatDuration(_durationSec), style: AppText.caption),
          ],
        ),
        if (_transcript.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text(
              _transcript,
              style: AppText.caption.copyWith(fontStyle: FontStyle.italic),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: 'Discard',
                variant: AppButtonVariant.ghost,
                onPressed: isSending ? null : _discard,
                expand: true,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: AppButton(
                label: 'Send',
                icon: Icons.send,
                onPressed: isSending ? null : _send,
                loading: isSending,
                expand: true,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Pulsing red "recording" dot shown next to the elapsed time while
/// recording. Reduced-motion aware (static dot when animations disabled).
class _RecPulseDot extends StatefulWidget {
  const _RecPulseDot();

  @override
  State<_RecPulseDot> createState() => _RecPulseDotState();
}

class _RecPulseDotState extends State<_RecPulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));
  late final Animation<double> _opacity = Tween<double>(begin: 1.0, end: 0.35)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

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
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: AppColors.red,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
