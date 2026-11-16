import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../l10n/l10n.dart';
import '../../../state/auth_state.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/settings_rows.dart';

/// Status under the name (batch 6): a preset or up to 40 characters of
/// custom text, cleared after 1 h / 8 h / 24 h / never. One PATCH on Save;
/// Clear sends `{}`. The result lands on the cached user so profile, thread
/// header and Settings show it at once.
class StatusScreen extends ConsumerStatefulWidget {
  const StatusScreen({super.key});

  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
  static const expiryOptions = <int?>[3600, 28800, 86400, null];
  static const customMax = 40;

  late final TextEditingController _custom;
  StatusPreset? _preset;
  int? _expiresInSec;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final u = ref.read(authProvider).user;
    _preset = u?.statusPreset;
    _custom = TextEditingController(text: u?.statusText ?? '');
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  String _expiryLabel(int? sec) {
    final l = context.l10n;
    return switch (sec) {
      3600 => l.statusOneHour,
      28800 => l.statusEightHours,
      86400 => l.statusOneDay,
      _ => l.statusNever,
    };
  }

  bool get _hasValue => _preset != null || _custom.text.trim().isNotEmpty;

  Future<void> _submit({required bool clear}) async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      final text = _custom.text.trim();
      final r = clear
          ? await ref.read(settingsRepositoryProvider).setStatus()
          : await ref.read(settingsRepositoryProvider).setStatus(
                preset: _preset,
                text: _preset == null && text.isNotEmpty ? text : null,
                expiresInSec: _expiresInSec,
              );
      final user = ref.read(authProvider).user;
      if (user != null) {
        ref.read(authProvider.notifier).setUser(user.copyWith(
              statusPreset: () => r.preset,
              statusText: () => r.text,
              statusExpiresAt: () => r.expiresAt,
            ));
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessages.forApi(e))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final user = ref.watch(authProvider).user;
    final hasServerStatus = user?.statusLabel() != null;
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.statusTitle)),
      body: ListView(
        key: const ValueKey('status-list'),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        children: [
          SettingsSection(
            title: l.statusPresets,
            children: [
              for (final p in StatusPreset.values)
                Column(
                  children: [
                    ListTile(
                      key: ValueKey('status-preset-${p.wire}'),
                      title: Text(p.label, style: AppText.bodyPrimary),
                      trailing: _preset == p
                          ? const Icon(Icons.check, color: AppColors.medBlue)
                          : null,
                      onTap: () => setState(() {
                        _preset = _preset == p ? null : p;
                        if (_preset != null) _custom.clear();
                      }),
                    ),
                    const Divider(height: 1, indent: AppSpacing.lg),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: AppTextField(
                  key: const ValueKey('status-custom'),
                  controller: _custom,
                  label: l.statusCustom,
                  hint: l.statusCustomHint,
                  maxLength: customMax,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (v) => setState(() {
                    if (v.trim().isNotEmpty) _preset = null;
                  }),
                ),
              ),
            ],
          ),
          SettingsSection(
            title: l.statusClearAfter,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
                child: Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final o in expiryOptions)
                      ChoiceChip(
                        key: ValueKey('status-expiry-${o == null ? 'never' : '$o'}'),
                        label: Text(_expiryLabel(o)),
                        selected: _expiresInSec == o,
                        selectedColor: AppColors.medBlue.withValues(alpha: 0.15),
                        onSelected: (_) => setState(() => _expiresInSec = o),
                      ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppButton(
                  key: const ValueKey('status-save'),
                  label: l.statusSave,
                  onPressed: _hasValue ? () => _submit(clear: false) : null,
                  loading: _saving,
                  expand: true,
                ),
                if (hasServerStatus) ...[
                  const SizedBox(height: AppSpacing.sm),
                  AppButton(
                    key: const ValueKey('status-clear'),
                    label: l.statusClear,
                    variant: AppButtonVariant.ghost,
                    onPressed: () => _submit(clear: true),
                    expand: true,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
