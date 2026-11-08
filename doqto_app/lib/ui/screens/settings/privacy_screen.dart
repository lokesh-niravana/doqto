import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/models/network_profile.dart';
import '../../../state/privacy_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/section_card.dart';

/// Settings → Privacy (batch 2). Every row is a switch or a radio sheet; each
/// change saves on its own with a one-field PATCH, flips at once and rolls
/// back with a toast if the server refuses. No text inputs on this screen.
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  /// Mirrors DISAPPEAR_OPTIONS_SEC on the backend + the chat details sheet.
  static const timerOptions = <(int?, String)>[
    (null, Strings.privacyTimerOff),
    (86400, '24 hours'),
    (604800, '7 days'),
    (2592000, '30 days'),
    (7776000, '90 days'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(privacyProvider);
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.privacyTitle)),
      body: async.when(
        loading: () => const _PrivacySkeleton(),
        error: (e, _) =>
            _ErrorPane(onRetry: () => ref.invalidate(privacyProvider)),
        data: (p) => _PrivacyBody(settings: p),
      ),
    );
  }
}

class _PrivacyBody extends ConsumerWidget {
  final PrivacySettings settings;
  const _PrivacyBody({required this.settings});

  Future<void> _save(
    BuildContext context,
    WidgetRef ref, {
    required PrivacySettings Function(PrivacySettings) apply,
    required Map<String, dynamic> patch,
  }) async {
    try {
      await ref
          .read(privacyProvider.notifier)
          .change(apply: apply, patch: patch);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(Strings.privacySaveFailed)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = settings;
    return ListView(
      key: const ValueKey('privacy-list'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      children: [
        FadeSlideIn.staggered(
          0,
          _Section(
            title: Strings.privacyWhoCanSee,
            footer: Strings.privacyReciprocalHint,
            children: [
              _ChoiceRow<LastSeenVisibility>(
                field: 'last_seen_visibility',
                title: Strings.privacyLastSeen,
                value: p.lastSeenVisibility,
                options: const [
                  (
                    LastSeenVisibility.everyone,
                    Strings.privacyLastSeenEveryone,
                  ),
                  (
                    LastSeenVisibility.connections,
                    Strings.privacyLastSeenConnections,
                  ),
                  (LastSeenVisibility.nobody, Strings.privacyLastSeenNobody),
                ],
                wire: (v) => v.wire,
                onPick: (v) => _save(
                  context,
                  ref,
                  apply: (s) => s.copyWith(lastSeenVisibility: v),
                  patch: {'last_seen_visibility': v.wire},
                ),
              ),
              _ChoiceRow<OnlineVisibility>(
                field: 'online_visibility',
                title: Strings.privacyOnline,
                value: p.onlineVisibility,
                options: const [
                  (OnlineVisibility.sameAsLastSeen, Strings.privacyOnlineSame),
                  (OnlineVisibility.nobody, Strings.privacyOnlineNobody),
                ],
                wire: (v) => v.wire,
                onPick: (v) => _save(
                  context,
                  ref,
                  apply: (s) => s.copyWith(onlineVisibility: v),
                  patch: {'online_visibility': v.wire},
                ),
              ),
              _ChoiceRow<ProfileFieldVisibility>(
                field: 'profile_photo_visibility',
                title: Strings.privacyProfilePhoto,
                value: p.profilePhotoVisibility,
                options: const [
                  (
                    ProfileFieldVisibility.everyone,
                    Strings.privacyLastSeenEveryone,
                  ),
                  (
                    ProfileFieldVisibility.connections,
                    Strings.privacyLastSeenConnections,
                  ),
                ],
                wire: (v) => v.wire,
                onPick: (v) => _save(
                  context,
                  ref,
                  apply: (s) => s.copyWith(profilePhotoVisibility: v),
                  patch: {'profile_photo_visibility': v.wire},
                ),
              ),
              _ChoiceRow<ProfileFieldVisibility>(
                field: 'about_visibility',
                title: Strings.privacyAbout,
                value: p.aboutVisibility,
                options: const [
                  (
                    ProfileFieldVisibility.everyone,
                    Strings.privacyLastSeenEveryone,
                  ),
                  (
                    ProfileFieldVisibility.connections,
                    Strings.privacyLastSeenConnections,
                  ),
                ],
                wire: (v) => v.wire,
                onPick: (v) => _save(
                  context,
                  ref,
                  apply: (s) => s.copyWith(aboutVisibility: v),
                  patch: {'about_visibility': v.wire},
                ),
                last: true,
              ),
            ],
          ),
        ),
        FadeSlideIn.staggered(
          1,
          _Section(
            title: Strings.privacyMessaging,
            children: [
              _SwitchRow(
                field: 'read_receipts',
                title: Strings.privacyReadReceipts,
                subtitle: Strings.privacyReadReceiptsHint,
                value: p.readReceipts,
                onChanged: (v) => _save(
                  context,
                  ref,
                  apply: (s) => s.copyWith(readReceipts: v),
                  patch: {'read_receipts': v},
                ),
              ),
              _ChoiceRow<int?>(
                field: 'default_disappear_sec',
                title: Strings.privacyDefaultTimer,
                subtitle: Strings.privacyDefaultTimerHint,
                value: p.defaultDisappearSec,
                options: PrivacyScreen.timerOptions,
                wire: (v) => v == null ? 'off' : '$v',
                onPick: (v) => _save(
                  context,
                  ref,
                  apply: (s) => s.copyWith(defaultDisappearSec: () => v),
                  patch: {'default_disappear_sec': v},
                ),
              ),
              _SwitchRow(
                field: 'link_previews',
                title: Strings.privacyLinkPreviews,
                subtitle: Strings.privacyLinkPreviewsHint,
                value: p.linkPreviews,
                onChanged: (v) => _save(
                  context,
                  ref,
                  apply: (s) => s.copyWith(linkPreviews: v),
                  patch: {'link_previews': v},
                ),
                last: true,
              ),
            ],
          ),
        ),
        FadeSlideIn.staggered(
          2,
          _Section(
            title: Strings.privacyNetwork,
            children: [
              _ChoiceRow<InvitePolicy>(
                field: 'invite_policy',
                title: Strings.privacyInvitePolicy,
                value: p.invitePolicy,
                options: const [
                  (InvitePolicy.everyone, 'Everyone'),
                  (InvitePolicy.secondDegree, 'Connections of connections'),
                  (
                    InvitePolicy.sharedGroupOrOrg,
                    'Shared group or organization',
                  ),
                  (InvitePolicy.nobody, 'Nobody'),
                ],
                wire: (v) => v.wire,
                onPick: (v) => _save(
                  context,
                  ref,
                  apply: (s) => s.copyWith(invitePolicy: v),
                  patch: {'invite_policy': v.wire},
                ),
              ),
              _ChoiceRow<Discoverability>(
                field: 'discoverability',
                title: Strings.privacyDiscoverability,
                value: p.discoverability,
                options: const [
                  (Discoverability.everyone, 'Everyone'),
                  (Discoverability.connections, 'Connections only'),
                  (Discoverability.nobody, 'Nobody'),
                ],
                wire: (v) => v.wire,
                onPick: (v) => _save(
                  context,
                  ref,
                  apply: (s) => s.copyWith(discoverability: v),
                  patch: {'discoverability': v.wire},
                ),
              ),
              _SwitchRow(
                field: 'show_mutual_connections',
                title: Strings.privacyShowMutuals,
                subtitle: Strings.privacyShowMutualsHint,
                value: p.showMutualConnections,
                onChanged: (v) => _save(
                  context,
                  ref,
                  apply: (s) => s.copyWith(showMutualConnections: v),
                  patch: {'show_mutual_connections': v},
                ),
                last: true,
              ),
            ],
          ),
        ),
        FadeSlideIn.staggered(
          3,
          _Section(
            title: Strings.privacyBlocked,
            children: [
              ListTile(
                key: const ValueKey('privacy-row-blocked'),
                leading: const Icon(Icons.block, color: AppColors.red),
                title: Text(Strings.privacyBlocked, style: AppText.bodyPrimary),
                subtitle: Text(
                  Strings.privacyBlockedHint,
                  style: AppText.caption,
                ),
                trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                onTap: () => context.push(AppRoutes.privacyBlocked),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? footer;
  final List<Widget> children;
  const _Section({required this.title, required this.children, this.footer});

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

class _SwitchRow extends StatelessWidget {
  final String field;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool last;

  const _SwitchRow({
    required this.field,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile.adaptive(
          key: ValueKey('privacy-switch-$field'),
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

/// A row whose value is picked from a bottom sheet of options.
class _ChoiceRow<T> extends StatelessWidget {
  final String field;
  final String title;
  final String? subtitle;
  final T value;
  final List<(T, String)> options;
  final String Function(T) wire;
  final ValueChanged<T> onPick;
  final bool last;

  const _ChoiceRow({
    required this.field,
    required this.title,
    required this.value,
    required this.options,
    required this.wire,
    required this.onPick,
    this.subtitle,
    this.last = false,
  });

  String get _valueLabel {
    for (final (v, label) in options) {
      if (v == value) return label;
    }
    return '—';
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<(T,)>(
      context: context,
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
                  child: Text(subtitle!, style: AppText.caption),
                ),
              for (final (v, label) in options)
                ListTile(
                  key: ValueKey('privacy-opt-$field-${wire(v)}'),
                  title: Text(label, style: AppText.bodyPrimary),
                  trailing: v == value
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
          key: ValueKey('privacy-row-$field'),
          title: Text(title, style: AppText.bodyPrimary),
          subtitle: Text(
            _valueLabel,
            key: ValueKey('privacy-value-$field'),
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

class _ErrorPane extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorPane({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              Strings.netErrorGeneric,
              style: AppText.body,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: Strings.retry,
              onPressed: onRetry,
              variant: AppButtonVariant.secondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacySkeleton extends StatelessWidget {
  const _PrivacySkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenHorizontal,
        vertical: AppSpacing.xl,
      ),
      children: [
        AppSkeleton.line(width: 120),
        const SizedBox(height: AppSpacing.sm),
        AppSkeleton.block(height: 220),
        const SizedBox(height: AppSpacing.lg),
        AppSkeleton.line(width: 96),
        const SizedBox(height: AppSpacing.sm),
        AppSkeleton.block(height: 180),
      ],
    );
  }
}
