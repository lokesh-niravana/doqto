import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/enums/app_enums.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'app_text_field.dart';
import 'primary_button.dart';

/// Human label for each [ReportReason] (the picker renders from the enum).
String reportReasonLabel(ReportReason r) => switch (r) {
      ReportReason.spam => 'Spam or promotion',
      ReportReason.harassment => 'Harassment',
      ReportReason.phiMisuse => 'Patient information misuse',
      ReportReason.impersonation => 'Impersonation',
      ReportReason.other => 'Something else',
    };

/// What the sheet hands back when the doctor sends it.
class MessageReport {
  final ReportReason reason;
  final String? details;
  const MessageReport(this.reason, this.details);
}

/// "Report message" (batch 4): a reason picker plus optional details.
/// Keys: `report-reason-<wire>`, `report-details`, `report-submit`.
Future<MessageReport?> showReportMessageSheet(BuildContext context) {
  return showModalBottomSheet<MessageReport>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => const _ReportSheet(),
  );
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet();

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportReason? _reason;
  final _details = TextEditingController();

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Keep the details field above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            key: const ValueKey('report-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xs),
                child: Text(Strings.chatReportTitle, style: AppText.heading),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Text(Strings.chatReportHint, style: AppText.caption),
              ),
              const SizedBox(height: AppSpacing.sm),
              RadioGroup<ReportReason>(
                groupValue: _reason,
                onChanged: (v) => setState(() => _reason = v),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final r in ReportReason.values)
                      RadioListTile<ReportReason>(
                        key: ValueKey('report-reason-${r.wire}'),
                        dense: true,
                        value: r,
                        activeColor: AppColors.medBlue,
                        title: Text(reportReasonLabel(r), style: AppText.bodyPrimary),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
                child: AppTextField(
                  key: const ValueKey('report-details'),
                  controller: _details,
                  label: Strings.chatReportDetails,
                  hint: 'What happened?',
                  maxLines: 3,
                  maxLength: 1000,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: AppButton(
                  key: const ValueKey('report-submit'),
                  label: Strings.chatReportSubmit,
                  expand: true,
                  onPressed: _reason == null
                      ? null
                      : () => Navigator.of(context).pop(
                            MessageReport(_reason!, _details.text.trim().isEmpty ? null : _details.text.trim()),
                          ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
