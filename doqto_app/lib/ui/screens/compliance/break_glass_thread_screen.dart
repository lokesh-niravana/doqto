import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/message.dart';
import '../../../state/compliance_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/primary_button.dart';

/// The audited read behind an approved break-glass request (batch 7).
/// Read-only: no composer, no context menu, no copy. A persistent red banner
/// says what this is, because every page here is audited and the members
/// were told. Newest first from the server, rendered oldest at the top.
class BreakGlassThreadScreen extends ConsumerStatefulWidget {
  final String requestId;
  const BreakGlassThreadScreen({super.key, required this.requestId});

  @override
  ConsumerState<BreakGlassThreadScreen> createState() => _BreakGlassThreadScreenState();
}

class _BreakGlassThreadScreenState extends ConsumerState<BreakGlassThreadScreen> {
  final _rows = <Message>[];
  String? _cursor;
  bool _loading = true;
  bool _more = false;
  Object? _error;

  String? get _orgId => ref.read(orgProvider).current?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool older = false}) async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref.read(complianceRepositoryProvider).accessRequestMessages(
            orgId,
            widget.requestId,
            cursor: older ? _cursor : null,
          );
      if (!mounted) return;
      setState(() {
        if (!older) _rows.clear();
        _rows.addAll(page.data);
        _cursor = page.nextCursor;
        _more = page.nextCursor != null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  String _name(String userId) {
    final orgId = _orgId;
    if (orgId == null) return userId;
    final members = ref.read(orgMembersProvider(orgId)).asData?.value ?? const [];
    for (final m in members) {
      if (m.id == userId) return m.fullName;
    }
    return 'Member ${userId.substring(0, userId.length.clamp(0, 8))}';
  }

  @override
  Widget build(BuildContext context) {
    final org = ref.watch(orgProvider).current;
    final request = org == null
        ? null
        : ref
            .watch(accessRequestsProvider(org.id))
            .asData
            ?.value
            .where((r) => r.id == widget.requestId)
            .firstOrNull;
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.breakGlassTitle)),
      body: Column(
        children: [
          Container(
            key: const ValueKey('break-glass-banner'),
            width: double.infinity,
            color: AppColors.red,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
            child: Row(
              children: [
                const Icon(Icons.gavel_rounded, color: AppColors.white, size: 16),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    Strings.breakGlassBanner,
                    style: AppText.caption.copyWith(color: AppColors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          if (request != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
              child: Text(
                request.expiresAt == null
                    ? request.reason
                    : '${request.reason} · ${Strings.accessRequestAccessUntil(DateFormat.yMMMd().add_jm().format(request.expiresAt!.toLocal()))}',
                style: AppText.caption,
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _rows.isEmpty) return const SkeletonList();
    final error = _error;
    if (error != null && _rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(ErrorMessages.forApi(error), style: AppText.caption, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.lg),
              AppButton(label: Strings.retry, icon: Icons.refresh_rounded, onPressed: _load),
            ],
          ),
        ),
      );
    }
    if (_rows.isEmpty) {
      return const Center(child: Text(Strings.breakGlassEmpty));
    }
    // Server order is newest first; show oldest at the top, newest last,
    // with the "older" button above the first row — an audit read, not a chat.
    final more = _more ? 1 : 0;
    return ListView.builder(
      key: const ValueKey('break-glass-list'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: _rows.length + more,
      itemBuilder: (_, i) {
        if (_more && i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: AppButton(
              key: const ValueKey('break-glass-older'),
              label: Strings.breakGlassOlder,
              variant: AppButtonVariant.ghost,
              loading: _loading,
              expand: true,
              onPressed: _loading ? null : () => _load(older: true),
            ),
          );
        }
        final m = _rows[_rows.length - 1 - (i - more)];
        return _Row(message: m, senderName: _name(m.senderId));
      },
    );
  }
}

class _Row extends StatelessWidget {
  final Message message;
  final String senderName;
  const _Row({required this.message, required this.senderName});

  String get _body {
    final m = message;
    if (m.type == MessageType.system) return m.content ?? Strings.breakGlassSystem;
    final text = (m.content ?? '').trim();
    final label = switch (m.type) {
      MessageType.image => '[Photo]',
      MessageType.video => '[Video]',
      MessageType.file => '[Document] ${m.fileName ?? ''}'.trim(),
      MessageType.voiceNote => '[Voice note] ${m.transcript ?? ''}'.trim(),
      MessageType.poll => '[Poll] $text',
      _ => text,
    };
    final caption = (m.caption ?? '').trim();
    return caption.isEmpty || m.type == MessageType.text ? label : '$label\n$caption';
  }

  @override
  Widget build(BuildContext context) {
    final m = message;
    final system = m.type == MessageType.system;
    final when = DateFormat.yMMMd().add_jm().format(m.createdAt.toLocal());
    return Padding(
      key: ValueKey('break-glass-row-${m.id}'),
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: system ? AppColors.gray100 : AppColors.surface,
          borderRadius: AppRadii.rMd,
          border: m.isDeleted ? Border.all(color: AppColors.red) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    system ? Strings.breakGlassSystem : senderName,
                    style: AppText.label,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(when, style: AppText.timestamp),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            if (m.isDeleted)
              Text(
                Strings.breakGlassDeleted,
                key: ValueKey('break-glass-deleted-${m.id}'),
                style: AppText.caption.copyWith(color: AppColors.red),
              ),
            if (_body.isNotEmpty) SelectionContainer.disabled(child: Text(_body, style: AppText.messageBody)),
          ],
        ),
      ),
    );
  }
}
