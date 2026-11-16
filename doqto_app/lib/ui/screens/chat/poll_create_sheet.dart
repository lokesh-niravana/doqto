import 'package:flutter/material.dart';

import '../../../core/constants/strings.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/models/message.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/settings_rows.dart';

typedef PollDraft = ({String question, List<String> options, bool multiple});

/// Compose a poll (batch 5 I): question, 2–12 options, allow multiple.
/// Returns null when dismissed. Every field is an [AppTextField], so the
/// keyboard rule (tap outside dismisses) holds without extra wiring.
Future<PollDraft?> showPollCreateSheet(BuildContext context) {
  return showModalBottomSheet<PollDraft>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => const PollCreateSheet(),
  );
}

class PollCreateSheet extends StatefulWidget {
  const PollCreateSheet({super.key});

  @override
  State<PollCreateSheet> createState() => _PollCreateSheetState();
}

class _PollCreateSheetState extends State<PollCreateSheet> {
  final _question = TextEditingController();
  final _options = <TextEditingController>[TextEditingController(), TextEditingController()];
  bool _multiple = false;
  String? _error;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _filled => [for (final c in _options) c.text.trim()].where((t) => t.isNotEmpty).toList();

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

  bool get _canSend => validate() == null;

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

  void _send() {
    final err = validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop((question: _question.text.trim(), options: _filled, multiple: _multiple));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.sm, 0),
                child: Row(
                  children: [
                    Expanded(child: Text(Strings.pollCreateTitle, style: AppText.heading)),
                    IconButton(
                      key: const ValueKey('poll-close'),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
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
                                hint: Strings.pollOptionHint,
                                maxLength: PollData.optionMaxLen,
                                textCapitalization: TextCapitalization.sentences,
                                onChanged: (_) => setState(() => _error = null),
                              ),
                            ),
                            if (_options.length > PollData.minOptions)
                              IconButton(
                                key: ValueKey('poll-option-remove-$i'),
                                onPressed: () => _removeOption(i),
                                icon: Icon(Icons.remove_circle_outline, color: AppColors.textMuted),
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
                            const Icon(Icons.add_circle_outline, color: AppColors.medBlue, size: 20),
                            const SizedBox(width: AppSpacing.sm),
                            Text(Strings.pollAddOption, style: AppText.label.copyWith(color: AppColors.medBlue)),
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
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.sm),
                        child: Text(_error!, key: const ValueKey('poll-error'), style: AppText.caption.copyWith(color: AppColors.red)),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
                child: AppButton(
                  key: const ValueKey('poll-send'),
                  label: Strings.pollSend,
                  expand: true,
                  onPressed: _canSend ? _send : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
