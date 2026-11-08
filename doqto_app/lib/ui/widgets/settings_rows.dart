import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'section_card.dart';

/// Labelled card of rows, as on Settings → Privacy (batch 2) and Settings
/// (batch 3). Keys follow `<keyPrefix>-switch-<field>` / `-row-<field>` /
/// `-value-<field>` / `-opt-<field>-<wire>` so tests can address them.
class SettingsSection extends StatelessWidget {
  final String title;
  final String? footer;
  final List<Widget> children;
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenHorizontal,
        AppSpacing.sm,
        AppSpacing.screenHorizontal,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.xs,
              bottom: AppSpacing.sm,
            ),
            child: Text(title.toUpperCase(), style: AppText.label),
          ),
          SectionCard(
            padding: EdgeInsets.zero,
            child: Column(children: children),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.xs,
                top: AppSpacing.sm,
              ),
              child: Text(footer!, style: AppText.caption),
            ),
        ],
      ),
    );
  }
}

/// A switch row. Flips at once; the caller rolls back on failure.
class SettingsSwitchRow extends StatelessWidget {
  final String field;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool last;
  final String keyPrefix;

  const SettingsSwitchRow({
    super.key,
    required this.field,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.last = false,
    this.keyPrefix = 'privacy',
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile.adaptive(
          key: ValueKey('$keyPrefix-switch-$field'),
          title: Text(title, style: AppText.bodyPrimary),
          subtitle: subtitle == null
              ? null
              : Text(subtitle!, style: AppText.caption),
          value: value,
          activeTrackColor: AppColors.medBlue,
          onChanged: onChanged,
        ),
        if (!last) const Divider(height: 1, indent: AppSpacing.lg),
      ],
    );
  }
}

/// Bottom sheet of options with a check on the current one. Returns the
/// pick wrapped in a record (so a nullable choice like "Off" is told apart
/// from a dismissed sheet), or null when dismissed. Shared by
/// [SettingsChoiceRow] and the chat list's mute sheet.
Future<(T,)?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<(T, String)> options,
  required String Function(T) wire,
  T? value,
  String keyPrefix = 'privacy',
  String field = '',
}) async {
  final picked = await showModalBottomSheet<(T,)>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Text(title, style: AppText.heading),
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Text(subtitle, style: AppText.caption),
              ),
            for (final (v, label) in options)
              ListTile(
                key: ValueKey('$keyPrefix-opt-$field-${wire(v)}'),
                title: Text(label, style: AppText.bodyPrimary),
                trailing: value != null && v == value
                    ? const Icon(Icons.check, color: AppColors.medBlue)
                    : null,
                onTap: () => Navigator.of(ctx).pop((v,)),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    ),
  );
  return picked;
}

/// A row whose value is picked from a bottom sheet of options.
class SettingsChoiceRow<T> extends StatelessWidget {
  final String field;
  final String title;
  final String? subtitle;
  final T value;
  final List<(T, String)> options;
  final String Function(T) wire;
  final ValueChanged<T> onPick;
  final bool last;
  final String keyPrefix;

  const SettingsChoiceRow({
    super.key,
    required this.field,
    required this.title,
    required this.value,
    required this.options,
    required this.wire,
    required this.onPick,
    this.subtitle,
    this.last = false,
    this.keyPrefix = 'privacy',
  });

  String get _valueLabel {
    for (final (v, label) in options) {
      if (v == value) return label;
    }
    return '—';
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showChoiceSheet<T>(
      context,
      title: title,
      subtitle: subtitle,
      options: options,
      wire: wire,
      value: value,
      keyPrefix: keyPrefix,
      field: field,
    );
    if (picked == null) return;
    final next = picked.$1;
    if (next == value) return;
    onPick(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          key: ValueKey('$keyPrefix-row-$field'),
          title: Text(title, style: AppText.bodyPrimary),
          subtitle: Text(
            _valueLabel,
            key: ValueKey('$keyPrefix-value-$field'),
            style: AppText.caption.copyWith(color: AppColors.medBlue),
          ),
          trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
          onTap: () => _open(context),
        ),
        if (!last) const Divider(height: 1, indent: AppSpacing.lg),
      ],
    );
  }
}
