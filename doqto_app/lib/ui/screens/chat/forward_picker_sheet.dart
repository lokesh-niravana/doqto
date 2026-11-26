import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/strings.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/conversation.dart';
import '../../../data/models/network_profile.dart';
import '../../../state/auth_state.dart';
import '../../../state/chat_state.dart';
import '../../../state/network_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/load_failed.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/search_bar.dart';
import '../../../core/utils/avatar_urls.dart';

/// Where a forward goes: an existing chat, or a connection without one yet
/// (the caller opens the direct chat first — the server hands back an
/// existing one when there is).
class ForwardTarget {
  final String? conversationId;
  final String? userId;
  final String name;
  const ForwardTarget({this.conversationId, this.userId, required this.name});

  String get key => conversationId ?? 'user:$userId';
}

/// The forward picker (batch 4): recent chats first, then people you can
/// message, multi-select up to [max]. Returns the picks or null.
Future<List<ForwardTarget>?> showForwardPicker(
  BuildContext context, {
  required String excludeConversationId,
}) {
  return showModalBottomSheet<List<ForwardTarget>>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    // Full-height sheet: keep it out from under the status bar / notch.
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ForwardPickerSheet(excludeConversationId: excludeConversationId),
  );
}

class ForwardPickerSheet extends ConsumerStatefulWidget {
  final String excludeConversationId;
  static const int max = 5;

  const ForwardPickerSheet({super.key, required this.excludeConversationId});

  @override
  ConsumerState<ForwardPickerSheet> createState() => _ForwardPickerSheetState();
}

class _ForwardPickerSheetState extends ConsumerState<ForwardPickerSheet> {
  String _query = '';
  final _picked = <String, ForwardTarget>{};

  /// Set by a tap on a sixth chat. Shown as a line inside the sheet: a
  /// SnackBar would be drawn by the screen underneath, where the sheet
  /// hides it.
  bool _limitHit = false;

  void _toggle(ForwardTarget t) {
    setState(() {
      if (_picked.containsKey(t.key)) {
        _picked.remove(t.key);
        _limitHit = false;
      } else if (_picked.length < ForwardPickerSheet.max) {
        _picked[t.key] = t;
      } else {
        _limitHit = true;
        HapticFeedback.heavyImpact();
      }
    });
  }

  bool _match(String s) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty || s.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final meId = ref.watch(authProvider).user?.id;
    final convsAsync = ref.watch(conversationsProvider);
    final peopleAsync = ref.watch(connectionsProvider);
    // `valueOrNull` keeps the last good list through a reload or a failed refresh.
    final convs = convsAsync.valueOrNull ?? const <Conversation>[];
    final people = peopleAsync.valueOrNull ?? const <PersonCard>[];
    // A source with nothing to show yet is not "no chats": it is still
    // loading, or it failed and gets a Retry.
    final convsFailed = convsAsync.hasError && !convsAsync.isLoading;
    final peopleFailed = peopleAsync.hasError && !peopleAsync.isLoading;
    final loadError = convsFailed
        ? convsAsync.error
        : peopleFailed
            ? peopleAsync.error
            : null;
    final loading = (convsAsync.isLoading && !convsAsync.hasValue) ||
        (peopleAsync.isLoading && !peopleAsync.hasValue);
    void retry() {
      if (convsFailed) ref.invalidate(conversationsProvider);
      if (peopleFailed) ref.invalidate(connectionsProvider);
    }

    final recent = [
      for (final c in convs)
        if (c.id != widget.excludeConversationId && !c.prefs.archived && c.access != ConversationAccess.pendingRequest)
          c,
    ]..sort((a, b) => (b.lastMessageAt ?? b.updatedAt).compareTo(a.lastMessageAt ?? a.updatedAt));
    final withChat = <String>{
      for (final c in recent)
        if (c.type == ConversationType.direct)
          for (final id in c.memberIds)
            if (id != meId) id,
    };
    final others = [
      for (final p in people)
        if (!withChat.contains(p.id) && p.id != meId) p,
    ];

    String titleOf(Conversation c) => c.type == ConversationType.group
        ? (c.name ?? 'Group')
        : (c.displayName ?? 'Direct chat');

    final shownRecent = recent.where((c) => _match(titleOf(c))).toList();
    final shownOthers = others.where((p) => _match(p.fullName)).toList();
    final nothingShown = shownRecent.isEmpty && shownOthers.isEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          key: const ValueKey('forward-picker'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, 0),
              child: Row(
                children: [
                  Expanded(child: Text(Strings.chatForwardTitle, style: AppText.heading)),
                  Text(
                    '${_picked.length}/${ForwardPickerSheet.max}',
                    key: const ValueKey('forward-count'),
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            if (_limitHit)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 0),
                child: Semantics(
                  liveRegion: true,
                  child: Row(
                    key: const ValueKey('forward-limit'),
                    children: [
                      const Icon(Icons.error_outline_rounded, size: 16, color: AppColors.red),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          Strings.chatForwardLimit,
                          style: AppText.caption.copyWith(color: AppColors.red, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            AppSearchBar(hint: Strings.chatForwardHint, onChanged: (q) => setState(() => _query = q)),
            Expanded(
              child: nothingShown && loading
                  ? const SkeletonList(key: ValueKey('forward-loading'))
                  : nothingShown && loadError != null
                      ? SingleChildScrollView(
                          child: LoadFailed(
                            key: const ValueKey('forward-load-failed'),
                            message: ErrorMessages.forApi(loadError),
                            onRetry: retry,
                          ),
                        )
                      : ListView(
                children: [
                  if (shownRecent.isNotEmpty) const _Header('RECENT CHATS'),
                  for (final c in shownRecent)
                    _row(
                      ForwardTarget(conversationId: c.id, name: titleOf(c)),
                      initials: _initials(titleOf(c)),
                      subtitle: c.type == ConversationType.group ? 'Group' : null,
                      colorSeed: c.id,
                      isGroup: c.type == ConversationType.group,
                    ),
                  if (shownOthers.isNotEmpty) const _Header('PEOPLE'),
                  for (final p in shownOthers)
                    _row(
                      ForwardTarget(userId: p.id, name: p.fullName),
                      initials: p.initials,
                      subtitle: p.specialty,
                      colorSeed: p.id,
                      image: userAvatarUrl(p.id, p.avatarUrl),
                    ),
                  if (nothingShown)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      // Nothing typed and nothing listed: there are no chats
                      // to match against.
                      child: Text(
                        _query.trim().isEmpty ? Strings.forwardNoChatsYet : Strings.forwardNoMatch,
                        key: const ValueKey('forward-empty'),
                        style: AppText.caption,
                        textAlign: TextAlign.center,
                      ),
                    )
                  else if (loading)
                    // One source is in; the other is still on its way.
                    const Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: Strings.loading),
                        ),
                      ),
                    )
                  else if (loadError != null)
                    // One source failed with the other's rows on screen.
                    Padding(
                      key: const ValueKey('forward-partial-error'),
                      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InlineError(ErrorMessages.forApi(loadError)),
                          const SizedBox(height: AppSpacing.sm),
                          AppButton(
                            key: const ValueKey('forward-partial-retry'),
                            label: Strings.retry,
                            icon: Icons.refresh_rounded,
                            variant: AppButtonVariant.ghost,
                            expand: true,
                            onPressed: retry,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: AppButton(
                  key: const ValueKey('forward-confirm'),
                  label: _picked.isEmpty
                      ? Strings.chatForward
                      : '${Strings.chatForward} · ${_picked.values.map((t) => t.name.split(' ').first).join(', ')}',
                  expand: true,
                  icon: Icons.shortcut_rounded,
                  onPressed: _picked.isEmpty ? null : () => Navigator.of(context).pop(_picked.values.toList()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
  }

  Widget _row(
    ForwardTarget t, {
    required String initials,
    required String colorSeed,
    String? subtitle,
    String? image,
    bool isGroup = false,
  }) {
    final selected = _picked.containsKey(t.key);
    return ListTile(
      key: ValueKey('forward-target-${t.key}'),
      selected: selected,
      selectedColor: AppColors.textPrimary,
      leading: isGroup
          ? CircleAvatar(
              backgroundColor: AppColors.medBlueLight,
              foregroundColor: AppColors.medBlue,
              child: const Icon(Icons.group_outlined),
            )
          : DoctorAvatar(initials: initials, colorIndex: colorSeed.hashCode, imageUrl: image, size: AvatarSize.md),
      title: Text(t.name, style: AppText.bodyPrimary, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null || subtitle.isEmpty ? null : Text(subtitle, style: AppText.caption),
      trailing: Icon(
        selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
        color: selected ? AppColors.medBlue : AppColors.gray400,
      ),
      onTap: () => _toggle(t),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xs),
        child: Semantics(header: true, child: Text(text, style: AppText.label)),
      );
}
