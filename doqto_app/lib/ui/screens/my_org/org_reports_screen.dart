import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/strings.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/compliance.dart';
import '../../../state/compliance_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_pill.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/report_message_sheet.dart' show reportReasonLabel;
import '../../widgets/section_card.dart';
import '../../widgets/settings_rows.dart';
import 'access_requests_screen.dart' show showCreateAccessRequestSheet;
import '../../../core/utils/async_retry.dart';
import '../../widgets/app_pressable.dart';
import '../../widgets/refresh_feedback.dart';

String reportStatusLabel(ReportStatus s) => switch (s) {
      ReportStatus.open => Strings.orgReportStatusOpen,
      ReportStatus.reviewing => Strings.orgReportStatusReviewing,
      ReportStatus.actioned => Strings.orgReportStatusActioned,
      ReportStatus.dismissed => Strings.orgReportStatusDismissed,
    };

PillTone _tone(ReportStatus s) => switch (s) {
      ReportStatus.open => PillTone.danger,
      ReportStatus.reviewing => PillTone.warn,
      ReportStatus.actioned => PillTone.success,
      ReportStatus.dismissed => PillTone.neutral,
    };

/// My Org → Reports (batch 7, org moderation). Reports whose reporter or
/// subject is a member: reason, details, the ids involved — never a message
/// body. Tap a card to move it between statuses.
class OrgReportsScreen extends ConsumerStatefulWidget {
  const OrgReportsScreen({super.key});

  @override
  ConsumerState<OrgReportsScreen> createState() => _OrgReportsScreenState();
}

class _OrgReportsScreenState extends ConsumerState<OrgReportsScreen> {
  ReportStatus? _filter; // null = all

  @override
  Widget build(BuildContext context) {
    final org = ref.watch(orgProvider).current;
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.orgReportsTitle)),
      body: org == null
          ? const SizedBox.shrink()
          : Column(
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
                  child: Row(
                    children: [
                      AppChip(
                        key: const ValueKey('reports-filter-all'),
                        label: Strings.orgReportsFilterAll,
                        selected: _filter == null,
                        onTap: () => setState(() => _filter = null),
                      ),
                      for (final s in ReportStatus.values) ...[
                        const SizedBox(width: AppSpacing.sm),
                        AppChip(
                          key: ValueKey('reports-filter-${s.wire}'),
                          label: reportStatusLabel(s),
                          selected: _filter == s,
                          onTap: () => setState(() => _filter = s),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: ref.watch(orgReportsProvider(org.id)).whenRetrying(
                        loading: () => const SkeletonList(),
                        error: (e, _) => Center(
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.xl),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Semantics(
                                  container: true,
                                  liveRegion: true,
                                  child: Text(ErrorMessages.forApi(e), style: AppText.caption, textAlign: TextAlign.center),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                AppButton(
                                  label: Strings.retry,
                                  icon: Icons.refresh_rounded,
                                  onPressed: () => ref.invalidate(orgReportsProvider(org.id)),
                                ),
                              ],
                            ),
                          ),
                        ),
                        data: (all) {
                          final rows = [
                            for (final r in all)
                              if (_filter == null || r.status == _filter) r,
                          ];
                          // Reports exist, none with the chosen status:
                          // "No reports" would say the org has none.
                          if (rows.isEmpty) return _Empty(filtered: all.isNotEmpty);
                          return RefreshIndicator(
                            onRefresh: () => refreshWithFeedback(
                              context,
                              () => ref.read(orgReportsProvider(org.id).notifier).refresh(rethrowOnError: true),
                            ),
                            child: ListView.separated(
                              key: const ValueKey('reports-list'),
                              padding: EdgeInsets.fromLTRB(
                                AppSpacing.screenHorizontal,
                                AppSpacing.sm,
                                AppSpacing.screenHorizontal,
                                MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
                              ),
                              itemCount: rows.length,
                              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
                              itemBuilder: (_, i) => _ReportCard(orgId: org.id, report: rows[i]),
                            ),
                          );
                        },
                      ),
                ),
              ],
            ),
    );
  }
}

class _ReportCard extends ConsumerWidget {
  final String orgId;
  final OrgReport report;
  const _ReportCard({required this.orgId, required this.report});

  Future<void> _changeStatus(BuildContext context, WidgetRef ref) async {
    final picked = await showChoiceSheet<ReportStatus>(
      context,
      title: Strings.orgReportChangeStatus,
      options: [for (final s in ReportStatus.values) (s, reportStatusLabel(s))],
      wire: (s) => s.wire,
      value: report.status,
      keyPrefix: 'report',
      field: 'status',
    );
    if (picked == null || picked.$1 == report.status) return;
    try {
      await ref.read(orgReportsProvider(orgId).notifier).setStatus(report.id, picked.$1);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(e))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = report;
    // Null while loading: a neutral placeholder, then a name, or words for
    // someone no longer in the list. Never a fragment of the id.
    final members = ref.watch(orgMembersProvider(orgId)).asData?.value;
    String name(String id) {
      if (members == null) return Strings.namePlaceholder;
      for (final m in members) {
        if (m.id == id) return m.fullName;
      }
      return Strings.formerMember;
    }

    final when = DateFormat.yMMMd().add_jm().format(r.createdAt.toLocal());
    final details = (r.details ?? '').trim();
    final conversationId = r.conversationId;
    return SectionCard(
      key: ValueKey('report-${r.id}'),
      onTap: () => _changeStatus(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wraps onto a second line at a large text size instead of
          // overflowing; one line, ends apart, when both pills fit.
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                AppPill(
                  key: ValueKey('report-reason-${r.id}'),
                  label: reportReasonLabel(r.reason),
                  tone: PillTone.brand,
                ),
                // The visible, spoken way to change the status: the pill is
                // a menu button (chevron, "Change status, Open"). Tapping
                // the rest of the card still opens the same sheet.
                AppPressable(
                  key: ValueKey('report-status-change-${r.id}'),
                  minTarget: true,
                  semanticLabel:
                      '${Strings.orgReportChangeStatus}, ${reportStatusLabel(r.status)}',
                  onTap: () => _changeStatus(context, ref),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppPill(
                        key: ValueKey('report-status-${r.id}'),
                        label: reportStatusLabel(r.status),
                        tone: _tone(r.status),
                      ),
                      Icon(Icons.expand_more, size: 20, color: AppColors.gray600),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            r.subjectType == 'message' ? Strings.orgReportSubjectMessage : Strings.orgReportSubjectUser,
            style: AppText.bodyPrimary,
          ),
          Text(
            '${name(r.reporterId)} · $when',
            style: AppText.caption,
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(details, style: AppText.body),
          ],
          if (r.contextMessageIds.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(Strings.orgReportContext(r.contextMessageIds.length), style: AppText.timestamp),
          ],
          // A message report names a chat the admin usually isn't in and so
          // can't pick: ask for access to it from here. Nothing to ask for on
          // a report about a person.
          if (r.subjectType == 'message' && conversationId != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppButton(
              key: ValueKey('report-request-access-${r.id}'),
              label: Strings.accessRequestNew,
              icon: Icons.lock_open_rounded,
              variant: AppButtonVariant.secondary,
              expand: true,
              onPressed: () => showCreateAccessRequestSheet(
                context,
                ref,
                orgId,
                conversationId: conversationId,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  /// The status filter hid every report (there are some).
  final bool filtered;
  const _Empty({this.filtered = false});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: AppColors.medBlueLight, borderRadius: AppRadii.rFull),
                child: const Icon(Icons.flag_outlined, color: AppColors.medBlue, size: 30),
              ),
              const SizedBox(height: AppSpacing.lg),
              // Announced when it replaces the loading state or the list.
              Semantics(
                container: true,
                liveRegion: true,
                child: Text(
                  filtered ? Strings.orgReportsEmptyFiltered : Strings.orgReportsEmpty,
                  key: const ValueKey('reports-empty-title'),
                  style: AppText.heading,
                  textAlign: TextAlign.center,
                ),
              ),
              if (!filtered) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(Strings.orgReportsEmptyHint, style: AppText.body, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      );
}
