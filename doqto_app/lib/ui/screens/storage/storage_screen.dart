import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/models/media_settings.dart';
import '../../../data/services/network_usage.dart';
import '../../../state/media_settings_state.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/settings_rows.dart';

/// Storage and data (batch 5 G): upload quality, auto-download per media
/// type, a door to Manage storage, and the network counters. Everything on
/// this screen lives in the encrypted chat cache box.
class StorageScreen extends ConsumerWidget {
  const StorageScreen({super.key});

  static const _qualityOptions = [
    (UploadQuality.standard, 'Standard (1600 px)'),
    (UploadQuality.hd, 'HD (2560 px)'),
    (UploadQuality.original, 'Original'),
  ];

  static const _ruleOptions = [
    (AutoDownloadRule.never, Strings.storageNever),
    (AutoDownloadRule.wifi, Strings.storageWifiOnly),
    (AutoDownloadRule.always, Strings.storageWifiAndCellular),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(mediaSettingsProvider);
    final notifier = ref.read(mediaSettingsProvider.notifier);
    final usage = ref.watch(networkUsageProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(Strings.storageTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        children: [
          SettingsSection(
            title: Strings.storageManage,
            children: [
              AppPressable(
                key: const ValueKey('storage-manage'),
                onTap: () => context.push(AppRoutes.storageManage),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined, color: AppColors.medBlue),
                  title: Text(Strings.storageManage, style: AppText.bodyPrimary),
                  trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                ),
              ),
            ],
          ),
          SettingsSection(
            title: Strings.storageUploadQuality,
            footer: Strings.storageUploadQualityHint,
            children: [
              SettingsChoiceRow<UploadQuality>(
                keyPrefix: 'storage',
                field: 'quality',
                title: Strings.storageUploadQuality,
                value: settings.uploadQuality,
                options: _qualityOptions,
                wire: (q) => q.wire,
                onPick: notifier.setUploadQuality,
                last: true,
              ),
            ],
          ),
          SettingsSection(
            title: Strings.storageAutoDownload,
            footer: Strings.storageAutoDownloadHint,
            children: [
              for (final (i, kind) in MediaDownloadKind.values.indexed)
                SettingsChoiceRow<AutoDownloadRule>(
                  keyPrefix: 'storage',
                  field: kind.wire,
                  title: kind.label,
                  value: settings.ruleFor(kind),
                  options: _ruleOptions,
                  wire: (r) => r.wire,
                  onPick: (r) => notifier.setRule(kind, r),
                  last: i == MediaDownloadKind.values.length - 1,
                ),
            ],
          ),
          SettingsSection(
            title: Strings.storageNetworkUsage,
            footer: usage.since == null
                ? null
                : 'Since ${DateFormat.yMMMd().add_jm().format(usage.since!.toLocal())}',
            children: [
              _UsageRow(label: Strings.storageSent, value: NetworkUsage.format(usage.bytesSent), keyName: 'storage-sent'),
              _UsageRow(label: Strings.storageReceived, value: NetworkUsage.format(usage.bytesReceived), keyName: 'storage-received'),
              AppPressable(
                key: const ValueKey('storage-reset-usage'),
                onTap: usage.reset,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Text(Strings.storageResetUsage, style: AppText.bodyPrimary.copyWith(color: AppColors.red)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  final String label;
  final String value;
  final String keyName;
  const _UsageRow({required this.label, required this.value, required this.keyName});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppText.bodyPrimary)),
          Text(value, key: ValueKey(keyName), style: AppText.body.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
