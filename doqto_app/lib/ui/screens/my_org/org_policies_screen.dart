import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/strings.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/organization.dart';
import '../../../state/compliance_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/settings_rows.dart';

/// My Org → Policies (batch 7). Admins get switches and pickers that save
/// one key at a time (optimistic, rolled back with a toast); members get the
/// same list read-only under "Your organisation's policies". Legal hold and
/// retention confirm first: both destroy or preserve data org-wide.
class OrgPoliciesScreen extends ConsumerWidget {
  const OrgPoliciesScreen({super.key});

  /// Mirrors DISAPPEAR_OPTIONS_SEC on the backend.
  static const timerOptions = <(int?, String)>[
    (null, Strings.privacyTimerOff),
    (86400, '24 hours'),
    (604800, '7 days'),
    (2592000, '30 days'),
    (7776000, '90 days'),
  ];

  /// Retention presets within RETENTION_DAYS_MIN/MAX (1–3650).
  static const retentionOptions = <int?>[null, 30, 90, 180, 365, 730, 1825, 3650];

  static String retentionLabel(int? days) =>
      days == null ? Strings.orgPolicyRetentionForever : Strings.orgPolicyRetentionDays(days);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final org = ref.watch(orgProvider).current;
    final editable = ref.watch(isOrgAdminProvider);
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(
        title: Text(editable ? Strings.orgPoliciesTitle : Strings.myOrgMemberPolicies),
      ),
      body: org == null
          ? const SizedBox.shrink()
          : ref.watch(orgPoliciesProvider(org.id)).when(
                loading: () => const SkeletonList(),
                error: (e, _) => _ErrorPane(
                  message: ErrorMessages.forApi(e),
                  onRetry: () => ref.invalidate(orgPoliciesProvider(org.id)),
                ),
                data: (p) => _PoliciesBody(orgId: org.id, policies: p, editable: editable),
              ),
    );
  }
}

class _PoliciesBody extends ConsumerWidget {
  final String orgId;
  final OrgPolicies policies;
  final bool editable;
  const _PoliciesBody({required this.orgId, required this.policies, required this.editable});

  Future<void> _save(BuildContext context, WidgetRef ref, Map<String, dynamic> patch) async {
    try {
      await ref.read(orgPoliciesProvider(orgId).notifier).change(patch);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessages.forApi(e))),
      );
    }
  }

  Future<bool> _confirm(BuildContext context, {required String title, required String body}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: const ValueKey('policy-confirm-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(Strings.cancel),
          ),
          TextButton(
            key: const ValueKey('policy-confirm-ok'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(Strings.orgPolicyConfirm),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _setLegalHold(BuildContext context, WidgetRef ref, bool on) async {
    final ok = await _confirm(
      context,
      title: on ? Strings.orgPolicyLegalHoldOnTitle : Strings.orgPolicyLegalHoldOffTitle,
      body: on ? Strings.orgPolicyLegalHoldOnBody : Strings.orgPolicyLegalHoldOffBody,
    );
    if (!ok || !context.mounted) return;
    await _save(context, ref, {'legal_hold': on});
  }

  Future<void> _setRetention(BuildContext context, WidgetRef ref, int? days) async {
    if (days != null) {
      // Shortening (or starting) retention destroys messages; clearing it only keeps more.
      final ok = await _confirm(
        context,
        title: Strings.orgPolicyRetentionTitle,
        body: Strings.orgPolicyRetentionBody(OrgPoliciesScreen.retentionLabel(days)),
      );
      if (!ok || !context.mounted) return;
    }
    await _save(context, ref, {'retention_days': days});
  }

  Widget _bool(
    BuildContext context,
    WidgetRef ref, {
    required String field,
    required String title,
    required String hint,
    required bool value,
    bool last = false,
    Future<void> Function(bool)? onChanged,
  }) {
    if (!editable) {
      return _ReadOnlyRow(
        field: field,
        title: title,
        subtitle: hint,
        value: value ? Strings.policyOn : Strings.policyOff,
        last: last,
      );
    }
    return SettingsSwitchRow(
      keyPrefix: 'policy',
      field: field,
      title: title,
      subtitle: hint,
      value: value,
      last: last,
      onChanged: (v) => onChanged != null ? onChanged(v) : _save(context, ref, {field: v}),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = policies;
    return ListView(
      key: const ValueKey('policies-list'),
      padding: EdgeInsets.only(
        top: AppSpacing.lg,
        bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
      ),
      children: [
        FadeSlideIn.staggered(
          0,
          SettingsSection(
            title: Strings.orgPoliciesSectionContent,
            footer: editable ? null : Strings.orgPoliciesReadOnlyFooter,
            children: [
              _bool(context, ref,
                  field: 'allow_forward_outside_org',
                  title: Strings.orgPolicyForwardOutside,
                  hint: Strings.orgPolicyForwardOutsideHint,
                  value: p.allowForwardOutsideOrg),
              _bool(context, ref,
                  field: 'allow_copy',
                  title: Strings.orgPolicyAllowCopy,
                  hint: Strings.orgPolicyAllowCopyHint,
                  value: p.allowCopy),
              _bool(context, ref,
                  field: 'allow_media_export',
                  title: Strings.orgPolicyMediaExport,
                  hint: Strings.orgPolicyMediaExportHint,
                  value: p.allowMediaExport),
              _bool(context, ref,
                  field: 'block_screenshots',
                  title: Strings.orgPolicyBlockScreenshots,
                  hint: Strings.orgPolicyBlockScreenshotsHint,
                  value: p.blockScreenshots,
                  last: true),
            ],
          ),
        ),
        FadeSlideIn.staggered(
          1,
          SettingsSection(
            title: Strings.orgPoliciesSectionNotifications,
            children: [
              _bool(context, ref,
                  field: 'show_preview_in_banners_default',
                  title: Strings.orgPolicyPreviewDefault,
                  hint: Strings.orgPolicyPreviewDefaultHint,
                  value: p.showPreviewInBannersDefault,
                  last: true),
            ],
          ),
        ),
        FadeSlideIn.staggered(
          2,
          SettingsSection(
            title: Strings.orgPoliciesSectionRetention,
            children: [
              if (editable)
                SettingsChoiceRow<int?>(
                  keyPrefix: 'policy',
                  field: 'default_disappear_sec',
                  title: Strings.orgPolicyDefaultDisappear,
                  subtitle: Strings.orgPolicyDefaultDisappearHint,
                  value: p.defaultDisappearSec,
                  options: OrgPoliciesScreen.timerOptions,
                  wire: (v) => v?.toString() ?? 'off',
                  onPick: (v) => _save(context, ref, {'default_disappear_sec': v}),
                )
              else
                _ReadOnlyRow(
                  field: 'default_disappear_sec',
                  title: Strings.orgPolicyDefaultDisappear,
                  subtitle: Strings.orgPolicyDefaultDisappearHint,
                  value: OrgPoliciesScreen.timerOptions
                      .firstWhere((o) => o.$1 == p.defaultDisappearSec,
                          orElse: () => OrgPoliciesScreen.timerOptions.first)
                      .$2,
                ),
              if (editable)
                SettingsChoiceRow<int?>(
                  keyPrefix: 'policy',
                  field: 'retention_days',
                  title: Strings.orgPolicyRetention,
                  subtitle: Strings.orgPolicyRetentionHint,
                  value: p.retentionDays,
                  options: [
                    for (final d in OrgPoliciesScreen.retentionOptions)
                      (d, OrgPoliciesScreen.retentionLabel(d)),
                    // A value set outside the presets still shows and stays pickable.
                    if (p.retentionDays != null &&
                        !OrgPoliciesScreen.retentionOptions.contains(p.retentionDays))
                      (p.retentionDays, OrgPoliciesScreen.retentionLabel(p.retentionDays)),
                  ],
                  wire: (v) => v?.toString() ?? 'forever',
                  onPick: (v) => _setRetention(context, ref, v),
                )
              else
                _ReadOnlyRow(
                  field: 'retention_days',
                  title: Strings.orgPolicyRetention,
                  subtitle: Strings.orgPolicyRetentionHint,
                  value: OrgPoliciesScreen.retentionLabel(p.retentionDays),
                ),
              _bool(context, ref,
                  field: 'legal_hold',
                  title: Strings.orgPolicyLegalHold,
                  hint: Strings.orgPolicyLegalHoldHint,
                  value: p.legalHold,
                  last: true,
                  onChanged: (v) => _setLegalHold(context, ref, v)),
            ],
          ),
        ),
        if (p.legalHold)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenHorizontal),
            child: Container(
              key: const ValueKey('policy-legal-hold-note'),
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.amberLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.gavel_rounded, size: 18, color: AppColors.amberText),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      Strings.orgPolicyLegalHoldHint,
                      style: AppText.caption.copyWith(color: AppColors.amberText),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A member's view of one policy: title, hint and the value, no control.
class _ReadOnlyRow extends StatelessWidget {
  final String field;
  final String title;
  final String subtitle;
  final String value;
  final bool last;
  const _ReadOnlyRow({
    required this.field,
    required this.title,
    required this.subtitle,
    required this.value,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          ListTile(
            key: ValueKey('policy-readonly-$field'),
            title: Text(title, style: AppText.bodyPrimary),
            subtitle: Text(subtitle, style: AppText.caption),
            trailing: Text(
              value,
              key: ValueKey('policy-value-$field'),
              style: AppText.bodyPrimary.copyWith(color: AppColors.medBlue),
            ),
          ),
          if (!last) const Divider(height: 1, indent: AppSpacing.lg),
        ],
      );
}

class _ErrorPane extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorPane({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, style: AppText.caption, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.lg),
              AppButton(label: Strings.retry, icon: Icons.refresh_rounded, onPressed: onRetry),
            ],
          ),
        ),
      );
}
