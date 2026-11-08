import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/compliance.dart';

/// "Scheduled" from the thread menu (batch 7): my not-yet-sent scheduled
/// messages in this chat, soonest first, each with Cancel. The server keeps
/// no readable draft for the list, so rows show the send time only.
Future<void> showScheduledMessagesSheet(BuildContext context, String conversationId) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    builder: (_) => _ScheduledSheet(conversationId: conversationId),
  );
}

class _ScheduledSheet extends ConsumerStatefulWidget {
  final String conversationId;
  const _ScheduledSheet({required this.conversationId});

  @override
  ConsumerState<_ScheduledSheet> createState() => _ScheduledSheetState();
}

class _ScheduledSheetState extends ConsumerState<_ScheduledSheet> {
  List<ScheduledMessage>? _rows;
  Object? _error;
  final _cancelling = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await ref.read(complianceRepositoryProvider).scheduled(widget.conversationId);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _cancel(ScheduledMessage s) async {
    setState(() => _cancelling.add(s.id));
    try {
      await ref.read(complianceRepositoryProvider).cancelScheduled(s.id);
      if (!mounted) return;
      setState(() => _rows = [for (final r in _rows ?? const <ScheduledMessage>[]) if (r.id != s.id) r]);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(Strings.scheduledCancelled)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(e))));
    } finally {
      if (mounted) setState(() => _cancelling.remove(s.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return SafeArea(
      child: Padding(
        key: const ValueKey('scheduled-sheet'),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
              child: Text(Strings.scheduledTitle, style: AppText.heading),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text(ErrorMessages.forApi(_error!), style: AppText.caption),
              )
            else if (rows == null)
              const SizedBox(
                height: 96,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(Strings.scheduledEmpty, key: const ValueKey('scheduled-empty'), style: AppText.bodyPrimary),
                    const SizedBox(height: AppSpacing.xs),
                    Text(Strings.scheduledEmptyHint, style: AppText.caption),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: AppSpacing.lg),
                  itemBuilder: (_, i) {
                    final s = rows[i];
                    final local = s.scheduledAt.toLocal();
                    return ListTile(
                      key: ValueKey('scheduled-row-${s.id}'),
                      leading: Icon(
                        s.failed ? Icons.error_outline_rounded : Icons.schedule_send_rounded,
                        color: s.failed ? AppColors.red : AppColors.medBlue,
                      ),
                      title: Text(
                        DateFormat.yMMMEd().add_jm().format(local),
                        style: AppText.bodyPrimary,
                      ),
                      subtitle: Text(
                        s.failed ? (s.error ?? Strings.scheduledFailed) : Strings.scheduledPending,
                        style: AppText.caption.copyWith(color: s.failed ? AppColors.red : null),
                      ),
                      trailing: _cancelling.contains(s.id)
                          ? const SizedBox(
                              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : TextButton(
                              key: ValueKey('scheduled-cancel-${s.id}'),
                              onPressed: () => _cancel(s),
                              child: const Text(Strings.scheduledCancel),
                            ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
