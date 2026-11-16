import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/constants/strings.dart';
import '../../core/di/providers.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../core/utils/error_messages.dart';
import '../../data/models/message.dart';
import '../../data/models/network_profile.dart';
import 'doctor_avatar.dart';
import 'member_row.dart';
import '../../core/utils/avatar_urls.dart';

/// "Message info" for one of my own messages: who has read it, who has only
/// received it, who has neither — names, avatars, times. Fetched on open;
/// the server is the source of truth for receipts.
Future<void> showMessageReceiptsSheet({
  required BuildContext context,
  required Message message,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _ReceiptsSheet(message: message),
  );
}

class _ReceiptsSheet extends ConsumerWidget {
  final Message message;
  const _ReceiptsSheet({required this.message});

  static String _when(DateTime? t) {
    if (t == null) return '';
    final l = t.toLocal();
    final now = DateTime.now();
    final sameDay =
        l.year == now.year && l.month == now.month && l.day == now.day;
    return sameDay
        ? DateFormat.jm().format(l)
        : DateFormat.MMMd().add_jm().format(l);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_receiptsProvider(message.id));
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
              child: Text(Strings.groupMessageInfo, style: AppText.heading),
            ),
            Expanded(
              child: async.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Text(ErrorMessages.forApi(e),
                        style: AppText.caption, textAlign: TextAlign.center),
                  ),
                ),
                data: (rows) {
                  final read = [for (final r in rows) if (r.read) r];
                  final delivered = [
                    for (final r in rows) if (r.delivered && !r.read) r,
                  ];
                  final pending = [for (final r in rows) if (!r.delivered) r];
                  return ListView(
                    key: const ValueKey('receipts-list'),
                    children: [
                      _group(Strings.groupReadBy, read, Icons.done_all_rounded,
                          AppColors.medBlue, (r) => r.readAt),
                      _group(Strings.groupDeliveredTo, delivered,
                          Icons.done_all_rounded, AppColors.gray400,
                          (r) => r.deliveredAt),
                      _group(Strings.groupNotYetDelivered, pending,
                          Icons.done_rounded, AppColors.gray400, (_) => null),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _group(
    String label,
    List<MessageReceipt> rows,
    IconData icon,
    Color iconColor,
    DateTime? Function(MessageReceipt) timeOf,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenHorizontal, AppSpacing.md,
              AppSpacing.screenHorizontal, AppSpacing.xs),
          child: Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: AppSpacing.xs),
              Text('$label · ${rows.length}', style: AppText.label),
            ],
          ),
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenHorizontal),
            child: Text('—', style: AppText.caption),
          ),
        for (final r in rows)
          MemberRow(
            key: ValueKey('receipt-${r.userId}'),
            avatar: DoctorAvatar(
              initials: initialsOf(r.fullName),
              colorIndex: avatarIndexFrom(r.avatarColor, r.userId),
              imageUrl: userAvatarUrl(r.userId, r.avatarUrl),
              size: AvatarSize.sm,
            ),
            title: r.fullName,
            trailing: Text(_when(timeOf(r)), style: AppText.caption),
          ),
      ],
    );
  }
}

final _receiptsProvider = FutureProvider.autoDispose
    .family<List<MessageReceipt>, String>((ref, messageId) =>
        ref.read(chatRepositoryProvider).messageReceipts(messageId));
