import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/models/conversation_prefs.dart';
import '../../../data/models/notification_settings.dart';
import '../../../data/services/tone_player.dart';
import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/notification_settings_state.dart';

/// Tone picker (batch 6). [target] is `messages`, `groups` or a conversation
/// id (per-chat custom tone). Tapping a row previews the tone and saves it;
/// Default / None save silently. Keys: `tone-<name>`.
class TonePickerScreen extends ConsumerStatefulWidget {
  final String? target;
  const TonePickerScreen({super.key, this.target});

  @override
  ConsumerState<TonePickerScreen> createState() => _TonePickerScreenState();
}

class _TonePickerScreenState extends ConsumerState<TonePickerScreen> {
  late final TonePlayer _player;

  @override
  void initState() {
    super.initState();
    _player = ref.read(tonePlayerProvider);
  }

  String get _target => widget.target ?? 'messages';
  bool get _isKind => _target == 'messages' || _target == 'groups';

  /// The value currently stored for this target.
  String _current() {
    if (_isKind) {
      final s = ref.watch(notificationSettingsProvider).valueOrNull ??
          NotificationSettings.defaults;
      return _target == 'messages' ? s.messagesTone : s.groupsTone;
    }
    final prefs = ref
            .watch(conversationsProvider)
            .valueOrNull
            ?.where((c) => c.id == _target)
            .firstOrNull
            ?.prefs ??
        ConversationPrefs.defaults;
    return prefs.customTone ?? NotificationTones.systemDefault;
  }

  Future<void> _pick(String tone) async {
    // Preview first so the sound lands even if the save is slow.
    await _player.play(tone);
    try {
      if (_isKind) {
        await ref.read(notificationSettingsProvider.notifier).change(
              apply: (s) => _target == 'messages'
                  ? s.copyWith(messagesTone: tone)
                  : s.copyWith(groupsTone: tone),
              patch: {'${_target}_tone': tone},
            );
      } else {
        final notifier = ref.read(conversationsProvider.notifier);
        final prefs = notifier.conversation(_target)?.prefs ??
            ConversationPrefs.defaults;
        final value = tone == NotificationTones.systemDefault ? null : tone;
        await notifier.setPrefs(
          _target,
          optimistic: prefs.copyWith(customTone: () => value),
          patch: {'custom_tone': value},
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.commonSaveFailed)));
    }
  }

  @override
  void dispose() {
    _player.stop();
    super.dispose();
  }

  String _label(String tone) {
    final l = context.l10n;
    return switch (tone) {
      NotificationTones.systemDefault => l.toneDefault,
      NotificationTones.none => l.toneNone,
      _ => NotificationTones.label(tone),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final current = _current();
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.toneTitle)),
      body: ListView(
        key: const ValueKey('tone-list'),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Text(l.toneHint, style: AppText.caption),
          ),
          for (final tone in NotificationTones.all)
            ListTile(
              key: ValueKey('tone-$tone'),
              leading: Icon(
                tone == NotificationTones.none
                    ? Icons.notifications_off_outlined
                    : tone == NotificationTones.systemDefault
                        ? Icons.smartphone_rounded
                        : Icons.music_note_rounded,
                color: tone == current ? AppColors.medBlue : AppColors.textMuted,
              ),
              title: Text(_label(tone), style: AppText.bodyPrimary),
              trailing: tone == current
                  ? const Icon(Icons.check, color: AppColors.medBlue)
                  : null,
              onTap: () => _pick(tone),
            ),
        ],
      ),
    );
  }
}
