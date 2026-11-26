import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/compliance.dart';
import '../../../data/models/conversation.dart';
import '../../../data/models/organization.dart';
import '../../../state/auth_state.dart';
import '../../../state/chat_state.dart';
import '../../../state/compliance_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/app_pill.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/section_card.dart';
import '../../../core/utils/async_retry.dart';
import '../../widgets/refresh_feedback.dart';

const _rejectTitle = 'Reject this request?';
const _rejectBodySuffix =
    ' will not get access to this conversation and would have to ask again.';

/// My Org → Access requests (batch 7, break-glass). Lists the org's requests
/// newest first; a different admin approves or rejects a pending one; the
/// requester opens the audited read while the 24 h window is open.
class AccessRequestsScreen extends ConsumerWidget {
  const AccessRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final org = ref.watch(orgProvider).current;
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.accessRequestsTitle)),
      floatingActionButton: org == null
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('access-request-new'),
              backgroundColor: AppColors.medBlue,
              foregroundColor: AppColors.white,
              onPressed: () => showCreateAccessRequestSheet(context, ref, org.id),
              icon: const Icon(Icons.lock_open_rounded),
              label: const Text(Strings.accessRequestNew),
            ),
      body: org == null
          ? const SizedBox.shrink()
          : ref.watch(accessRequestsProvider(org.id)).whenRetrying(
                loading: () => const SkeletonList(),
                error: (e, _) => _Error(
                  message: ErrorMessages.forApi(e),
                  onRetry: () => ref.invalidate(accessRequestsProvider(org.id)),
                ),
                data: (rows) => rows.isEmpty
                    ? const _Empty()
                    : RefreshIndicator(
                        onRefresh: () => refreshWithFeedback(
                          context,
                          () => ref.read(accessRequestsProvider(org.id).notifier).refresh(rethrowOnError: true),
                        ),
                        child: ListView.separated(
                          key: const ValueKey('access-requests-list'),
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.screenHorizontal,
                            AppSpacing.lg,
                            AppSpacing.screenHorizontal,
                            MediaQuery.paddingOf(context).bottom + 96,
                          ),
                          itemCount: rows.length,
                          separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
                          itemBuilder: (_, i) => _RequestCard(orgId: org.id, request: rows[i]),
                        ),
                      ),
              ),
    );
  }
}

String accessRequestStatusLabel(AccessRequestStatus s) => switch (s) {
      AccessRequestStatus.pending => Strings.accessRequestStatusPending,
      AccessRequestStatus.approved => Strings.accessRequestStatusApproved,
      AccessRequestStatus.rejected => Strings.accessRequestStatusRejected,
      AccessRequestStatus.expired => Strings.accessRequestStatusExpired,
    };

PillTone _statusTone(AccessRequestStatus s) => switch (s) {
      AccessRequestStatus.pending => PillTone.warn,
      AccessRequestStatus.approved => PillTone.success,
      AccessRequestStatus.rejected => PillTone.danger,
      AccessRequestStatus.expired => PillTone.neutral,
    };

class _RequestCard extends ConsumerStatefulWidget {
  final String orgId;
  final AccessRequest request;
  const _RequestCard({required this.orgId, required this.request});

  @override
  ConsumerState<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends ConsumerState<_RequestCard> {
  /// The decision being sent (true = approve), null when idle. Only that
  /// button spins; the other is disabled.
  bool? _deciding;
  bool get _busy => _deciding != null;

  /// [members] is null while the member list is still loading: a neutral
  /// placeholder then, and words — never a fragment of an id — for someone
  /// who isn't in the list once it has loaded.
  String _name(String userId, List<OrgMember>? members, String? me) {
    if (userId == me) return Strings.accessRequestYou;
    if (members == null) return Strings.namePlaceholder;
    for (final m in members) {
      if (m.id == userId) return m.fullName;
    }
    return Strings.formerMember;
  }

  Future<void> _decide(bool approve, String requesterName) async {
    if (approve) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(Strings.accessRequestApproveTitle),
          content: Text(Strings.accessRequestApproveBody(requesterName)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(Strings.cancel)),
            TextButton(
              key: const ValueKey('access-request-approve-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(Strings.accessRequestApprove),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    } else {
      // A rejection is final for this request (the requester has to file a
      // new one), so it is confirmed like the approval is.
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(_rejectTitle),
          content: Text('$requesterName$_rejectBodySuffix'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(Strings.cancel)),
            TextButton(
              key: const ValueKey('access-request-reject-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
              child: const Text(Strings.accessRequestReject),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _deciding = approve);
    try {
      await ref
          .read(accessRequestsProvider(widget.orgId).notifier)
          .decide(widget.request.id, approve: approve);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(e))));
    } finally {
      if (mounted) setState(() => _deciding = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final me = ref.watch(authProvider).user?.id;
    final members = ref.watch(orgMembersProvider(widget.orgId)).asData?.value;
    final conv = ref.watch(conversationsProvider).asData?.value.where((c) => c.id == r.conversationId).firstOrNull;
    final mine = r.requesterId == me;
    final when = DateFormat.yMMMd().add_jm().format(r.createdAt.toLocal());
    final requester = _name(r.requesterId, members, me);
    return SectionCard(
      key: ValueKey('access-request-card-${r.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  conv == null ? Strings.conversationNotMine : conversationTitle(conv),
                  style: AppText.bodyPrimary,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              AppPill(
                key: ValueKey('access-request-status-${r.id}'),
                label: accessRequestStatusLabel(r.status),
                tone: _statusTone(r.status),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${Strings.accessRequestRequestedBy(requester)} · $when',
            style: AppText.caption,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(r.reason, style: AppText.body),
          const SizedBox(height: AppSpacing.md),
          if (r.status == AccessRequestStatus.pending && !mine)
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    key: ValueKey('access-request-reject-${r.id}'),
                    label: Strings.accessRequestReject,
                    variant: AppButtonVariant.danger,
                    loading: _deciding == false,
                    expand: true,
                    onPressed: _busy ? null : () => _decide(false, requester),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppButton(
                    key: ValueKey('access-request-approve-${r.id}'),
                    label: Strings.accessRequestApprove,
                    loading: _deciding == true,
                    expand: true,
                    onPressed: _busy ? null : () => _decide(true, requester),
                  ),
                ),
              ],
            )
          else if (r.status == AccessRequestStatus.pending)
            Text(Strings.accessRequestAwaitingOther, style: AppText.caption)
          else if (r.status == AccessRequestStatus.approved && r.expiresAt != null) ...[
            Text(
              Strings.accessRequestAccessUntil(
                DateFormat.yMMMd().add_jm().format(r.expiresAt!.toLocal()),
              ),
              style: AppText.caption,
            ),
            if (mine && r.readable) ...[
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                key: ValueKey('access-request-open-${r.id}'),
                label: Strings.accessRequestOpen,
                icon: Icons.visibility_outlined,
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: () => context.push(AppRoutes.accessRequestMessages(r.id)),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Title of a chat as the picker and the cards show it.
String conversationTitle(Conversation c) =>
    (c.displayName ?? c.name ?? '').trim().isEmpty ? Strings.conversationUnnamed : (c.displayName ?? c.name)!;

/// Pick a conversation from my own chats; a reason is required. The server
/// checks the conversation involves an org member.
///
/// [conversationId] pre-selects a conversation the admin can't pick — the
/// one a message report is about. It is sent, never shown: the field reads
/// the chat's title when the admin is in it, "The reported conversation"
/// otherwise.
Future<void> showCreateAccessRequestSheet(
  BuildContext context,
  WidgetRef ref,
  String orgId, {
  String? conversationId,
}) async {
  final created = await showModalBottomSheet<AccessRequest>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    useRootNavigator: true,
    builder: (_) => _CreateSheet(orgId: orgId, presetConversationId: conversationId),
  );
  if (created != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(Strings.accessRequestCreated)),
    );
  }
}

class _CreateSheet extends ConsumerStatefulWidget {
  final String orgId;
  final String? presetConversationId;
  const _CreateSheet({required this.orgId, this.presetConversationId});

  @override
  ConsumerState<_CreateSheet> createState() => _CreateSheetState();
}

class _CreateSheetState extends ConsumerState<_CreateSheet> {
  final _conv = TextEditingController();
  final _reason = TextEditingController();
  final _convFocus = FocusNode();
  final _reasonFocus = FocusNode();
  String? _convError;
  String? _reasonError;
  bool _busy = false;
  String? _submitError;
  Conversation? _picked;

  /// Opened from a report: the conversation is fixed, there is nothing to pick.
  bool get _preset => widget.presetConversationId != null;

  @override
  void initState() {
    super.initState();
    final id = widget.presetConversationId;
    if (id == null) return;
    final mine = ref
        .read(conversationsProvider)
        .asData
        ?.value
        .where((c) => c.id == id)
        .firstOrNull;
    _conv.text = mine == null ? Strings.accessRequestReportedConversation : conversationTitle(mine);
  }

  @override
  void dispose() {
    _conv.dispose();
    _reason.dispose();
    _convFocus.dispose();
    _reasonFocus.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    _convFocus.unfocus();
    _reasonFocus.unfocus();
    final picked = await showModalBottomSheet<Conversation>(
      context: context,
      useRootNavigator: true,
      // Watches the chats: while they are still loading the sheet says so
      // (a spinner), and fills in when they arrive — it used to read them
      // once and show "no chats" for a list that simply hadn't loaded.
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
        final convs = ref.watch(conversationsProvider);
        final list = convs.valueOrNull ?? const <Conversation>[];
        final loading = !convs.hasValue && convs.isLoading;
        final failed = !convs.hasValue && convs.hasError && !convs.isLoading;
        return SafeArea(
        child: ListView(
          key: const ValueKey('access-request-picker'),
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
              child: Text(Strings.accessRequestPickConversation, style: AppText.heading),
            ),
            for (final c in list)
              ListTile(
                key: ValueKey('access-request-pick-${c.id}'),
                // The title only: an id means nothing to the person choosing.
                title: Text(conversationTitle(c), style: AppText.bodyPrimary),
                onTap: () => Navigator.pop(ctx, c),
              ),
            if (loading)
              const Padding(
                key: ValueKey('access-request-picker-loading'),
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      semanticsLabel: Strings.loading,
                    ),
                  ),
                ),
              )
            else if (failed)
              Padding(
                key: const ValueKey('access-request-picker-failed'),
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpacing.sm,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(Strings.chatsLoadFailed, style: AppText.caption),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      onPressed: () => ref.invalidate(conversationsProvider),
                      child: const Text(Strings.retry),
                    ),
                  ],
                ),
              )
            else if (list.isEmpty)
              Padding(
                key: const ValueKey('access-request-picker-empty'),
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
                child: Text(Strings.accessRequestNoChats, style: AppText.caption),
              ),
          ],
        ),
        );
        },
      ),
    );
    if (picked == null) return;
    setState(() {
      // The field shows the chat's name; [_submit] sends its id.
      _picked = picked;
      _conv.text = conversationTitle(picked);
      _convError = null;
    });
  }

  Future<void> _submit() async {
    _convFocus.unfocus();
    _reasonFocus.unfocus();
    // The id travels with the choice; the field only ever shows a title.
    final convId = widget.presetConversationId ?? _picked?.id ?? '';
    final reason = _reason.text.trim();
    setState(() {
      _convError = convId.isEmpty ? Strings.accessRequestConversationRequired : null;
      _reasonError = reason.isEmpty ? Strings.accessRequestReasonRequired : null;
    });
    if (_convError != null || _reasonError != null) return;
    setState(() {
      _busy = true;
      _submitError = null;
    });
    try {
      final created = await ref
          .read(accessRequestsProvider(widget.orgId).notifier)
          .create(conversationId: convId, reason: reason);
      if (!mounted) return;
      Navigator.of(context).pop(created);
    } catch (e) {
      if (!mounted) return;
      // Shown in the sheet: a snackbar would sit underneath it, unseen.
      setState(() {
        _busy = false;
        _submitError = ErrorMessages.forApi(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    // Watched so my chats are loading (and stay loaded) while the sheet is
    // up: the picker reads them, and it is the only way to choose one.
    ref.watch(conversationsProvider);
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          key: const ValueKey('access-request-sheet'),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(Strings.accessRequestNew, style: AppText.heading),
              const SizedBox(height: AppSpacing.xs),
              Text(Strings.accessRequestsEmptyHint, style: AppText.caption),
              const SizedBox(height: AppSpacing.lg),
              AppTextField(
                key: const ValueKey('access-request-conversation'),
                controller: _conv,
                focusNode: _convFocus,
                label: Strings.accessRequestConversation,
                hint: Strings.accessRequestConversationHint,
                errorText: _convError,
                // Chosen, never typed: the field shows the chat's title and
                // opens the picker. No keyboard, so nothing to dismiss.
                readOnly: true,
                onTap: _preset ? null : _pick,
                suffix: _preset
                    ? null
                    : IconButton(
                        key: const ValueKey('access-request-pick'),
                        tooltip: Strings.accessRequestPickConversation,
                        icon: const Icon(Icons.chat_bubble_outline_rounded),
                        onPressed: _pick,
                      ),
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                key: const ValueKey('access-request-reason'),
                controller: _reason,
                focusNode: _reasonFocus,
                label: Strings.accessRequestReason,
                hint: Strings.accessRequestReasonHint,
                errorText: _reasonError,
                maxLines: 3,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
              ),
              Semantics(
                liveRegion: true,
                child: InlineError(_submitError, key: const ValueKey('access-request-submit-error')),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                key: const ValueKey('access-request-submit'),
                label: Strings.accessRequestSubmit,
                expand: true,
                loading: _busy,
                onPressed: _busy ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

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
                child: const Icon(Icons.lock_outline_rounded, color: AppColors.medBlue, size: 30),
              ),
              const SizedBox(height: AppSpacing.lg),
              // Announced when it replaces the loading state.
              Semantics(
                container: true,
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(Strings.accessRequestsEmpty, style: AppText.heading, textAlign: TextAlign.center),
                    const SizedBox(height: AppSpacing.sm),
                    Text(Strings.accessRequestsEmptyHint, style: AppText.body, textAlign: TextAlign.center),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _Error extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _Error({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Announced when it replaces the loading state.
              Semantics(
                container: true,
                liveRegion: true,
                child: Text(message, style: AppText.caption, textAlign: TextAlign.center),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(label: Strings.retry, icon: Icons.refresh_rounded, onPressed: onRetry),
            ],
          ),
        ),
      );
}
