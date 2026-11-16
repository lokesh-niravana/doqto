import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/models/conversation.dart';
import '../../../data/models/organization.dart';
import '../../../data/services/network_usage.dart';
import '../../../state/auth_state.dart';
import '../../../state/chat_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/primary_button.dart';
import '../chat/_conversation_display.dart';

/// Per-conversation size of downloaded photos, videos, voice notes and
/// documents (batch 5 G), with "clear" per chat and for everything. Sizes
/// come from the media index kept in the encrypted cache box.
class ManageStorageScreen extends ConsumerStatefulWidget {
  const ManageStorageScreen({super.key});

  @override
  ConsumerState<ManageStorageScreen> createState() => _ManageStorageScreenState();
}

class _ManageStorageScreenState extends ConsumerState<ManageStorageScreen> {
  bool _busy = false;

  Map<String, int> _sizes() {
    final media = ref.read(chatMediaCacheProvider).sizesByConversation();
    final docs = ref.read(chatDocumentStoreProvider).sizesByConversation();
    final out = <String, int>{...media};
    for (final e in docs.entries) {
      out[e.key] = (out[e.key] ?? 0) + e.value;
    }
    out.removeWhere((_, v) => v <= 0);
    return out;
  }

  Future<bool> _confirm(String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text(Strings.cancel)),
          TextButton(
            key: const ValueKey('storage-clear-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(Strings.storageClearChat, style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _clearChat(String convId, String title) async {
    if (!await _confirm('${Strings.storageClearChat} $title?')) return;
    setState(() => _busy = true);
    try {
      await ref.read(chatMediaCacheProvider).clearConversation(convId);
      await ref.read(chatDocumentStoreProvider).clearConversation(convId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAll() async {
    if (!await _confirm('${Strings.storageClearAll}?')) return;
    setState(() => _busy = true);
    try {
      await ref.read(chatMediaCacheProvider).clear();
      await ref.read(chatDocumentStoreProvider).clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider).user;
    final convs = ref.watch(conversationsProvider).asData?.value ?? const <Conversation>[];
    final currentOrg = ref.watch(orgProvider).current;
    final orgMembers = currentOrg == null
        ? const <OrgMember>[]
        : (ref.watch(orgMembersProvider(currentOrg.id)).asData?.value ?? const <OrgMember>[]);
    final sizes = _sizes();
    final total = sizes.values.fold<int>(0, (a, b) => a + b);
    final rows = sizes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Scaffold(
      appBar: AppBar(title: const Text(Strings.storageManage)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              children: [
                Expanded(child: Text(Strings.storageTotal, style: AppText.subheading)),
                Text(NetworkUsage.format(total), key: const ValueKey('storage-total'), style: AppText.subheading.copyWith(color: AppColors.medBlue)),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Center(child: Text(Strings.storageEmpty, key: const ValueKey('storage-empty'), style: AppText.caption)),
            ),
          for (final (i, e) in rows.indexed)
            Builder(builder: (context) {
              final conv = convs.where((c) => c.id == e.key).firstOrNull;
              final display = conv == null
                  ? null
                  : conversationDisplay(c: conv, orgMembers: orgMembers, meId: me?.id, fallbackColorIndex: i);
              final title = display?.title ?? 'Chat';
              return ListTile(
                key: ValueKey('storage-row-${e.key}'),
                leading: DoctorAvatar(initials: display?.initials ?? '?', colorIndex: display?.colorIndex ?? i, size: AvatarSize.md),
                title: Text(title, style: AppText.bodyPrimary, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(NetworkUsage.format(e.value), key: ValueKey('storage-size-${e.key}'), style: AppText.caption),
                trailing: AppPressable(
                  key: ValueKey('storage-clear-${e.key}'),
                  onTap: _busy ? null : () => _clearChat(e.key, title),
                  minTarget: true,
                  child: Text(Strings.storageClearChat, style: AppText.label.copyWith(color: AppColors.red)),
                ),
              );
            }),
          if (rows.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: AppButton(
                key: const ValueKey('storage-clear-all'),
                label: Strings.storageClearAll,
                variant: AppButtonVariant.danger,
                expand: true,
                loading: _busy,
                onPressed: _busy ? null : _clearAll,
              ),
            ),
        ],
      ),
    );
  }
}
