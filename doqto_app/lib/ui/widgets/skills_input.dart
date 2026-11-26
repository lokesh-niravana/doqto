import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/constants/strings.dart';
import '../../core/tokens/typography.dart';
import 'silent_hint.dart';

const _addSkillLabel = 'Add skill';
const _removeSkillPrefix = 'Remove';

/// Chip-style tag editor. Mirrors backend limits (≤20 items, ≤40 chars each).
class SkillsInput extends StatefulWidget {
  final List<String> initial;
  final ValueChanged<List<String>> onChanged;
  final int maxItems;
  final int maxLength;

  /// What is typed in the field but not added yet. The form counts it as an
  /// unsaved edit, and adds it on Save ([SkillsInputState.commitDraft]).
  final ValueChanged<String>? onDraftChanged;

  const SkillsInput({
    super.key,
    required this.initial,
    required this.onChanged,
    this.onDraftChanged,
    this.maxItems = 20,
    this.maxLength = 40,
  });

  @override
  State<SkillsInput> createState() => SkillsInputState();
}

class SkillsInputState extends State<SkillsInput> {
  late final List<String> _skills;
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _skills = [...widget.initial];
    _controller.addListener(_onDraft);
  }

  String _lastDraft = '';
  void _onDraft() {
    final draft = _controller.text.trim();
    if (draft == _lastDraft) return;
    _lastDraft = draft;
    widget.onDraftChanged?.call(draft);
  }

  /// Adds whatever is typed but not yet added, as tapping + would. Called by
  /// the form on Save, so a skill typed and left in the field is not dropped.
  void commitDraft() => _add(keepFocus: false);

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add({bool keepFocus = true}) {
    final v = _controller.text.trim();
    if (v.isEmpty) return;
    if (_skills.length >= widget.maxItems) return;
    if (_skills.any((s) => s.toLowerCase() == v.toLowerCase())) {
      _controller.clear();
      return;
    }
    setState(() {
      _skills.add(v);
      _controller.clear();
    });
    widget.onChanged(_skills);
    if (keepFocus) _focus.requestFocus();
  }

  void _remove(int i) {
    setState(() => _skills.removeAt(i));
    widget.onChanged(_skills);
  }

  @override
  Widget build(BuildContext context) {
    final atLimit = _skills.length >= widget.maxItems;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_skills.isNotEmpty)
          Padding(
            // Each chip sits in a 44pt-tall cell (its remove target), so the
            // cells supply the vertical rhythm themselves.
            padding: EdgeInsets.zero,
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: 0,
              children: [
                for (var i = 0; i < _skills.length; i++)
                  _SkillChip(label: _skills[i], onDelete: () => _remove(i)),
              ],
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                // At the limit the placeholder is the explanation; say it.
                label: atLimit
                    ? 'You\'ve reached ${widget.maxItems} skills'
                    : Strings.a11ySkillField,
                child: TextField(
                controller: _controller,
                focusNode: _focus,
                enabled: !atLimit,
                onTapOutside: (_) => _focus.unfocus(),
                maxLength: widget.maxLength,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _add(),
                style: AppText.bodyPrimary,
                decoration: InputDecoration(
                  counterText: '',
                  hint: SilentHint(
                    atLimit
                        ? 'You\'ve reached ${widget.maxItems} skills'
                        : 'Add a skill and tap +',
                    fieldStyle: AppText.bodyPrimary,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: AppRadii.rMd,
                    borderSide: BorderSide(color: AppColors.gray200),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: AppRadii.rMd,
                    borderSide: BorderSide(color: AppColors.medBlue, width: 1.5),
                  ),
                  border: OutlineInputBorder(borderRadius: AppRadii.rMd),
                ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Semantics(
              button: true,
              enabled: !atLimit,
              label: _addSkillLabel,
              child: Material(
                color: atLimit ? AppColors.gray100 : AppColors.medBlue,
                borderRadius: AppRadii.rMd,
                child: InkWell(
                  borderRadius: AppRadii.rMd,
                  onTap: atLimit ? null : () => _add(),
                  child: Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.add,
                      color: atLimit ? AppColors.textMuted : AppColors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SkillChip extends StatelessWidget {
  final String label;
  final VoidCallback onDelete;

  const _SkillChip({required this.label, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    // The pill keeps its size; the remove control is a 44x44 target laid over
    // its trailing end, inside a 44pt-tall cell.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs + 2,
            ),
            decoration: BoxDecoration(
              color: AppColors.medBlueLight,
              borderRadius: AppRadii.rFull,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: AppColors.medBlueDark,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                ExcludeSemantics(
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: AppColors.medBlueDark,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: 44,
            child: Semantics(
              button: true,
              label: '$_removeSkillPrefix $label',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDelete,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
