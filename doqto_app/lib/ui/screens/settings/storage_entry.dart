import 'package:flutter/material.dart';

import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../l10n/l10n.dart';

/// Settings → Storage and data: placeholder until the media batch lands.
///
/// COORDINATOR: batch 5 (media) owns the real screen — network usage, media
/// auto-download per connection, storage manager with per-chat sizes. When it
/// merges, point `AppRoutes.storage` at that screen (app_router.dart imports
/// this file) and delete this placeholder. The `storage*` l10n keys here are
/// safe to drop at the same time.
class StorageSettingsScreen extends StatelessWidget {
  const StorageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.storageTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sd_storage_outlined, size: 48, color: AppColors.gray600),
              const SizedBox(height: AppSpacing.md),
              Text(
                l.storageComingSoon,
                key: const ValueKey('storage-placeholder'),
                style: AppText.body,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
