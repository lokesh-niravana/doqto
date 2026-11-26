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
import '../../widgets/load_failed.dart';

/// "Scheduled" from the thread menu (batch 7): my not-yet-sent scheduled
/// messages in this chat, soonest first, each with Cancel. The server keeps
/// no readable draft for the list, so rows show the send time only.
Future<void> showScheduledMessagesSheet(BuildContext context, String conversationId) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    // Sized to its content, up to 90% of the screen, and scrollable.
    isScrollControlled: true,
    useSafeArea: true,
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

  /// Result of the last cancel, shown as a line inside the sheet. A SnackBar
  /// would be drawn by the screen underneath, where this sheet hides it.
  String? _notice;
  bool _noticeIsError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_error != null) setState(() => _error = null);
    try {
      final rows = await ref.read(complianceRepositoryProvider).scheduled(widget.conversationId);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _cancel(ScheduledMessage s) async {
    // Cancelling drops the message for good (there is no draft to recover).
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('scheduled-cancel-confirm'),
        title: const Text(Strings.scheduledCancelConfirmTitle),
        content: const Text(Strings.scheduledCancelConfirmBody),
        actions: [
          TextButton(
            key: const ValueKey('scheduled-cancel-keep'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(Strings.scheduledCancelKeep),
          ),
          TextButton(
            key: const ValueKey('scheduled-cancel-yes'),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(Strings.scheduledCancelConfirm),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() {
      _cancelling.add(s.id);
      _notice = null;
    });
    try {
      await ref.read(complianceRepositoryProvider).cancelScheduled(s.id);
      if (!mounted) return;
      setState(() {
        _rows = [for (final r in _rows ?? const <ScheduledMessage>[]) if (r.id != s.id) r];
        _notice = Strings.scheduledCancelled;
        _noticeIsError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _notice = ErrorMessages.forApi(e);
        _noticeIsError = true;
      });
    } finally {
      if (mounted) setState(() => _cancelling.remove(s.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return SafeArea(
      child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
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
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
                child: Semantics(
                  liveRegion: true,
                  child: Row(
                    key: const ValueKey('scheduled-notice'),
                    children: [
                      Icon(
                        _noticeIsError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
                        size: 16,
                        color: _noticeIsError ? AppColors.red : AppColors.greenDark,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          _notice!,
                          style: AppText.caption.copyWith(
                            color: _noticeIsError ? AppColors.red : AppColors.greenDark,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_error != null)
              Flexible(
                child: SingleChildScrollView(
                  child: Center(
                    child: LoadFailed(message: ErrorMessages.forApi(_error!), onRetry: _load),
                  ),
                ),
              )
            else if (rows == null)
              const SizedBox(
                height: 96,
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: Strings.loading),
                ),
              )
            else if (rows.isEmpty)
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(Strings.scheduledEmpty, key: const ValueKey('scheduled-empty'), style: AppText.bodyPrimary),
                    const SizedBox(height: AppSpacing.xs),
                    Text(Strings.scheduledEmptyHint, style: AppText.caption),
                  ],
                ),
              ),
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
                        // `error` is a server code: show a sentence, never the code.
                        s.failed
                            ? ErrorMessages.forCode(s.error, fallback: Strings.scheduledFailed)
                            : Strings.scheduledPending,
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
      ),
    );
  }
}
