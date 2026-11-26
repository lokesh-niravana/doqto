import 'package:flutter/material.dart';

import '../../../core/constants/strings.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/message.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/settings_rows.dart';

typedef PollDraft = ({String question, List<String> options, bool multiple});

/// Compose a poll (batch 5 I): question, 2–12 options, allow multiple.
/// Returns null when dismissed. Every field is an [AppTextField], so the
/// keyboard rule (tap outside dismisses) holds without extra wiring.
///
/// With [onSend] the sheet sends the poll itself and closes only once that
/// succeeds: a failure is shown in the sheet with the draft intact, rather
/// than toasted after the draft is gone. The returned draft is then the one
/// that was sent.
Future<PollDraft?> showPollCreateSheet(
  BuildContext context, {
  Future<void> Function(PollDraft draft)? onSend,
}) {
  return showModalBottomSheet<PollDraft>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    // With the keyboard up the sheet is full height: keep it off the
    // status bar.
    useSafeArea: true,
    // A drag-down closes the route without asking (it skips PopScope), so a
    // draft could be lost by a stray swipe. Scrim tap, the close button and
    // back all go through the discard check in [PollCreateSheet].
    enableDrag: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => PollCreateSheet(onSend: onSend),
  );
}

class PollCreateSheet extends StatefulWidget {
  /// Sends the poll. The sheet awaits it, stays open if it throws, and pops
  /// with the draft when it completes. Null: Send just pops with the draft.
  final Future<void> Function(PollDraft draft)? onSend;
  const PollCreateSheet({super.key, this.onSend});

  @override
  State<PollCreateSheet> createState() => _PollCreateSheetState();
}

class _PollCreateSheetState extends State<PollCreateSheet> {
  final _question = TextEditingController();
  final _options = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];
  bool _multiple = false;
  String? _error;

  /// [PollCreateSheet.onSend] is in flight: Send shows its spinner and the
  /// sheet can't be dismissed from under the request.
  bool _sending = false;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _filled => [
    for (final c in _options) c.text.trim(),
  ].where((t) => t.isNotEmpty).toList();

  /// Validation that mirrors the server's: question present, 2–12 distinct
  /// non-empty options.
  String? validate() {
    if (_question.text.trim().isEmpty) return Strings.pollNeedQuestion;
    final opts = _filled;
    if (opts.length < PollData.minOptions) return Strings.pollNeedTwo;
    final lower = opts.map((o) => o.toLowerCase()).toSet();
    if (lower.length != opts.length) return Strings.pollDuplicate;
    return null;
  }

  /// Send is live once there is a question and two options typed. Anything
  /// else wrong (duplicate options) is explained by [_send] rather than by a
  /// button that is disabled for no stated reason.
  bool get _canSend =>
      _question.text.trim().isNotEmpty && _filled.length >= PollData.minOptions;

  void _addOption() {
    if (_options.length >= PollData.maxOptions) return;
    setState(() => _options.add(TextEditingController()));
  }

  void _removeOption(int i) {
    if (_options.length <= PollData.minOptions) return;
    final c = _options.removeAt(i);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
  }

  /// Something typed or changed that a dismissal would throw away.
  bool get _hasDraft =>
      _question.text.trim().isNotEmpty || _filled.isNotEmpty || _multiple;

  bool _confirming = false;

  /// Scrim tap, close button, system back: ask before dropping a draft.
  Future<void> _confirmDiscard() async {
    if (_confirming || _sending) return;
    _confirming = true;
    FocusScope.of(context).unfocus();
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(Strings.pollDiscardTitle),
        content: const Text(Strings.pollDiscardBody),
        actions: [
          TextButton(
            key: const ValueKey('poll-discard-keep'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(Strings.keepEditing),
          ),
          TextButton(
            key: const ValueKey('poll-discard-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text(Strings.discard),
          ),
        ],
      ),
    );
    _confirming = false;
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _send() async {
    if (_sending) return;
    final err = validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    FocusScope.of(context).unfocus();
    final PollDraft draft = (
      question: _question.text.trim(),
      options: _filled,
      multiple: _multiple,
    );
    final onSend = widget.onSend;
    if (onSend == null) {
      Navigator.of(context).pop(draft);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await onSend(draft);
    } catch (e) {
      // Stay open with everything typed; say why beside the Send button.
      if (mounted) {
        setState(() {
          _sending = false;
          _error = ErrorMessages.forApi(e);
        });
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(draft);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope(
      canPop: !_hasDraft && !_sending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.sm,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          Strings.pollCreateTitle,
                          style: AppText.heading,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('poll-close'),
                        tooltip: Strings.a11yClose,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.sm,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    children: [
                      AppTextField(
                        key: const ValueKey('poll-question'),
                        controller: _question,
                        label: Strings.pollQuestion,
                        hint: Strings.pollQuestionHint,
                        maxLength: PollData.questionMaxLen,
                        maxLines: 3,
                        textCapitalization: TextCapitalization.sentences,
                        autofocus: true,
                        onChanged: (_) => setState(() => _error = null),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(Strings.pollOptions, style: AppText.label),
                      const SizedBox(height: AppSpacing.xs),
                      for (var i = 0; i < _options.length; i++)
                        Padding(
                          key: ValueKey('poll-option-row-$i'),
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: AppTextField(
                                  key: ValueKey('poll-option-$i'),
                                  controller: _options[i],
                                  semanticLabel: Strings.a11yPollOption(i + 1),
                                  hint: Strings.pollOptionHint,
                                  maxLength: PollData.optionMaxLen,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  onChanged: (_) =>
                                      setState(() => _error = null),
                                ),
                              ),
                              if (_options.length > PollData.minOptions)
                                IconButton(
                                  key: ValueKey('poll-option-remove-$i'),
                                  tooltip: Strings.pollRemoveOption,
                                  onPressed: () => _removeOption(i),
                                  icon: Icon(
                                    Icons.remove_circle_outline,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      if (_options.length < PollData.maxOptions)
                        AppPressable(
                          key: const ValueKey('poll-add-option'),
                          onTap: _addOption,
                          minTarget: true,
                          child: Row(
                            children: [
                              const Icon(
                                Icons.add_circle_outline,
                                color: AppColors.medBlue,
                                size: 20,
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Text(
                                Strings.pollAddOption,
                                style: AppText.label.copyWith(
                                  color: AppColors.medBlue,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: AppSpacing.sm),
                      SettingsSwitchRow(
                        keyPrefix: 'poll',
                        field: 'multiple',
                        title: Strings.pollAllowMultiple,
                        value: _multiple,
                        onChanged: (v) => setState(() => _multiple = v),
                        last: true,
                      ),
                    ],
                  ),
                ),
                // Beside the button that raised it, outside the scrolling
                // form: at the end of the list it could be below the fold.
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Semantics(
                        container: true,
                        liveRegion: true,
                        child: Text(
                          _error!,
                          key: const ValueKey('poll-error'),
                          style: AppText.caption.copyWith(color: AppColors.red),
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: AppButton(
                    key: const ValueKey('poll-send'),
                    label: Strings.pollSend,
                    expand: true,
                    loading: _sending,
                    onPressed: _canSend ? _send : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
