import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/conversation.dart';
import '../../../data/models/group.dart';
import '../../../state/auth_state.dart';
import '../../../state/chat_state.dart';
import '../../../state/groups_state.dart';
import '../../widgets/app_pill.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/inline_banner.dart';
import '../../widgets/member_row.dart';
import '../../widgets/primary_button.dart';
import '../chat/chat_details_screen.dart' show kDisappearOptions;
import 'group_add_members_sheet.dart';

/// Group info, opened from the group chat's header (WhatsApp's "Group info"):
/// who the group is, what it's for, who is in it, and the way out. A doctor
/// who isn't a member (a pending invite) lands here instead of the chat and
/// gets Accept / Decline. Owner and admins get the management surface —
/// identity, members, settings, invite links — members only see the facts.
class GroupInfoScreen extends ConsumerWidget {
  final String groupId;
  const GroupInfoScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(groupDetailProvider(groupId));
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.groupInfoTitle)),
      body: async.when(
        skipLoadingOnReload: true,
        skipLoadingOnRefresh: true,
        loading: () => const SkeletonList(),
        error: (e, _) => _InlineError(
          message: ErrorMessages.forApi(e),
          onRetry: () => ref.invalidate(groupDetailProvider(groupId)),
        ),
        data: (group) => ListView(
          key: const ValueKey('group-info-list'),
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
          ),
          children: [
            _Identity(group: group),
            if (group.hasPendingInvite) ...[
              const SizedBox(height: AppSpacing.sm),
              _InviteBanner(group: group),
            ],
            const SizedBox(height: AppSpacing.sm),
            _About(group: group),
            if (group.canManage) ...[
              const SizedBox(height: AppSpacing.sm),
              _Settings(group: group),
              const SizedBox(height: AppSpacing.sm),
              _InviteLinks(group: group),
            ],
            const SizedBox(height: AppSpacing.sm),
            _Members(group: group),
            if (group.isMember) ...[
              const SizedBox(height: AppSpacing.sm),
              _Section(
                child: ListTile(
                  key: const ValueKey('group-leave'),
                  leading: const Icon(Icons.logout, color: AppColors.red),
                  title: Text(
                    Strings.groupLeave,
                    style: AppText.body.copyWith(color: AppColors.red),
                  ),
                  onTap: () => _leave(context, ref),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final me = ref.read(authProvider).user;
    if (me == null) return;
    final ok = await confirmDialog(
      context,
      message: Strings.netLeaveGroupConfirm,
      action: Strings.groupLeave,
    );
    if (!ok || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(groupDetailProvider(groupId).notifier).leave(me.id);
      messenger.showSnackBar(
        const SnackBar(content: Text(Strings.groupLeftToast)),
      );
      // Both this screen and the chat behind it are closed to a non-member.
      if (context.mounted) context.go(AppRoutes.groups);
    } catch (e) {
      showApiError(messenger, e);
    }
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

void showApiError(ScaffoldMessengerState messenger, Object e) {
  messenger.showSnackBar(SnackBar(
    content: Text(ErrorMessages.forApi(e)),
    backgroundColor: AppColors.red,
  ));
}

/// Two-button confirm; the action is red (every confirm here is destructive).
Future<bool> confirmDialog(
  BuildContext context, {
  required String message,
  required String action,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text(Strings.cancel),
        ),
        TextButton(
          key: const ValueKey('confirm-action'),
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.red),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// One-field edit dialog (group name / description). Returns the trimmed
/// text on Save, null on Cancel. `AppTextField` carries the keyboard rule.
Future<String?> _editTextDialog(
  BuildContext context, {
  required String title,
  required String initial,
  required int maxLength,
  bool multiline = false,
  bool required = true,
  required Key fieldKey,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: AppText.subheading),
      content: AppTextField(
        key: fieldKey,
        controller: controller,
        maxLength: maxLength,
        autofocus: true,
        keyboardType: multiline ? TextInputType.multiline : TextInputType.text,
        textCapitalization: TextCapitalization.sentences,
        maxLines: multiline ? 4 : 1,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text(Strings.cancel),
        ),
        TextButton(
          key: const ValueKey('edit-save'),
          onPressed: () {
            final v = controller.text.trim();
            if (required && v.isEmpty) return;
            Navigator.of(ctx).pop(v);
          },
          child: const Text(Strings.save),
        ),
      ],
    ),
  );
}

/// White band on the grey page, one per section.
class _Section extends StatelessWidget {
  final Widget child;
  const _Section({required this.child});

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: AppColors.white, child: child);
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const _SectionLabel(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenHorizontal,
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.xs,
        ),
        child: Row(
          children: [
            Expanded(child: Text(text, style: AppText.label)),
            ?trailing,
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// Identity: avatar, name, count. Owner/admin tap to edit.
// ---------------------------------------------------------------------------

class _Identity extends ConsumerStatefulWidget {
  final Group group;
  const _Identity({required this.group});

  @override
  ConsumerState<_Identity> createState() => _IdentityState();
}

class _IdentityState extends ConsumerState<_Identity> {
  bool _uploading = false;

  Group get group => widget.group;
  GroupDetailNotifier get _notifier =>
      ref.read(groupDetailProvider(group.id).notifier);

  Future<void> _rename() async {
    final v = await _editTextDialog(
      context,
      title: Strings.groupEditName,
      initial: group.name,
      maxLength: 100,
      fieldKey: const ValueKey('group-name-field'),
    );
    if (v == null || v == group.name || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _notifier.updateGroup(name: v);
    } catch (e) {
      showApiError(messenger, e);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_uploading) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final xfile = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (xfile == null) return;
      setState(() => _uploading = true);
      await _notifier.setAvatar(File(xfile.path));
    } catch (e) {
      showApiError(messenger, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _removeAvatar() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _notifier.removeAvatar();
    } catch (e) {
      showApiError(messenger, e);
    }
  }

  void _openPhotoSheet() {
    final hasAvatar = group.avatarUrl != null;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: AppColors.medBlue),
              title: const Text('Choose from library'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined,
                  color: AppColors.medBlue),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera);
              },
            ),
            if (hasAvatar)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: AppColors.red),
                title: Text(Strings.groupRemovePhoto,
                    style: AppText.body.copyWith(color: AppColors.red)),
                onTap: () {
                  Navigator.pop(ctx);
                  _removeAvatar();
                },
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final manage = group.canManage;
    return _Section(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenHorizontal,
          AppSpacing.md,
          AppSpacing.screenHorizontal,
          AppSpacing.lg,
        ),
        child: Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                GestureDetector(
                  key: const ValueKey('group-avatar'),
                  onTap: manage ? _openPhotoSheet : null,
                  child: DoctorAvatar(
                    initials: group.initials,
                    colorIndex: group.avatarIndex,
                    imageUrl: group.avatarPresignedUrl ?? group.avatarUrl,
                    size: AvatarSize.xxl,
                    heroTag: 'group-avatar-${group.id}',
                  ),
                ),
                if (_uploading)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (manage)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(AppSpacing.xs),
                      decoration: const BoxDecoration(
                        color: AppColors.medBlue,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.photo_camera,
                          size: 14, color: AppColors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            InkWell(
              key: const ValueKey('group-name'),
              onTap: manage ? _rename : null,
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(group.name,
                          style: AppText.heading,
                          textAlign: TextAlign.center),
                    ),
                    if (manage) ...[
                      const SizedBox(width: AppSpacing.xs),
                      Icon(Icons.edit_outlined,
                          size: 18, color: AppColors.textMuted),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              Strings.groupMemberCount(group.memberCount),
              style: AppText.caption,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Invite banner (pending invitee)
// ---------------------------------------------------------------------------

class _InviteBanner extends ConsumerStatefulWidget {
  final Group group;
  const _InviteBanner({required this.group});

  @override
  ConsumerState<_InviteBanner> createState() => _InviteBannerState();
}

class _InviteBannerState extends ConsumerState<_InviteBanner> {
  bool _busy = false;

  Future<void> _accept() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final id = widget.group.id;
    try {
      await ref.read(groupDetailProvider(id).notifier).acceptInvite();
      messenger.showSnackBar(
        const SnackBar(content: Text(Strings.groupJoinedToast)),
      );
      // Land in the chat: this info screen stays underneath.
      if (mounted) context.pushReplacement(AppRoutes.group(id));
    } catch (e) {
      showApiError(messenger, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(groupDetailProvider(widget.group.id).notifier)
          .declineInvite();
      messenger.showSnackBar(
        const SnackBar(content: Text(Strings.groupDeclinedToast)),
      );
      if (mounted) context.go(AppRoutes.groups);
    } catch (e) {
      showApiError(messenger, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Section(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const InlineBanner(
                tone: BannerTone.info,
                icon: Icons.mail_outline_rounded,
                text: Strings.groupInvitedBy,
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      key: const ValueKey('invite-decline'),
                      label: Strings.groupDecline,
                      variant: AppButtonVariant.secondary,
                      onPressed: _busy ? null : _decline,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AppButton(
                      key: const ValueKey('invite-accept'),
                      label: Strings.groupAccept,
                      loading: _busy,
                      onPressed: _busy ? null : _accept,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// About: description (editable for owner/admin), rules, created
// ---------------------------------------------------------------------------

class _About extends ConsumerWidget {
  final Group group;
  const _About({required this.group});

  String get _dmRule => switch (group.memberDmPolicy) {
        'open' => Strings.groupsDmOpen,
        'disabled' => Strings.groupsDmDisabled,
        _ => Strings.groupsDmRequest,
      };

  static String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final l = d.toLocal();
    return '${months[l.month - 1]} ${l.day}, ${l.year}';
  }

  Widget _line(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenHorizontal,
          vertical: AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppText.caption),
            const SizedBox(height: 2),
            Text(value, style: AppText.body),
          ],
        ),
      );

  Future<void> _editDescription(BuildContext context, WidgetRef ref) async {
    final v = await _editTextDialog(
      context,
      title: Strings.groupEditDescription,
      initial: group.description ?? '',
      maxLength: 1000,
      multiline: true,
      required: false,
      fieldKey: const ValueKey('group-description-field'),
    );
    if (v == null || v == (group.description ?? '') || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(groupDetailProvider(group.id).notifier).updateGroup(
            description: v,
          );
    } catch (e) {
      showApiError(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = group.canManage;
    final desc = group.description;
    final hasDesc = desc != null && desc.isNotEmpty;
    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(
            Strings.groupAboutLabel,
            trailing: manage
                ? IconButton(
                    key: const ValueKey('group-description-edit'),
                    tooltip: Strings.groupEditDescription,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _editDescription(context, ref),
                  )
                : null,
          ),
          if (hasDesc || manage)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenHorizontal,
                0,
                AppSpacing.screenHorizontal,
                AppSpacing.xs,
              ),
              child: hasDesc
                  ? Text(desc, style: AppText.body)
                  : InkWell(
                      onTap: () => _editDescription(context, ref),
                      child: Text(
                        Strings.groupAddDescription,
                        style: AppText.body.copyWith(color: AppColors.medBlue),
                      ),
                    ),
            ),
          _line(Strings.groupsRulesLabel, Strings.groupsPolicyInviteOnly),
          if (!manage) _line(Strings.groupsMemberMessagingLabel, _dmRule),
          if (group.adminsOnlyPosting && !manage)
            _line(Strings.groupSendMessagesLabel, Strings.groupSendAdmins),
          if (group.createdAt != null)
            _line(Strings.groupsCreatedLabel, _formatDate(group.createdAt!)),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings (owner / admin): post policy, DM policy, disappearing messages
// ---------------------------------------------------------------------------

class _Settings extends ConsumerWidget {
  final Group group;
  const _Settings({required this.group});

  static const _dmLabels = {
    'open': Strings.groupDmOpenShort,
    'request': Strings.groupDmRequestShort,
    'disabled': Strings.groupDmDisabledShort,
  };

  Future<void> _pick<T>(
    BuildContext context, {
    required String title,
    required Map<T, String> options,
    required T current,
    required Future<void> Function(T) apply,
    Key Function(T)? keyFor,
  }) async {
    final picked = await showModalBottomSheet<_Pick<T>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
              child: Text(title, style: AppText.heading),
            ),
            for (final e in options.entries)
              ListTile(
                key: keyFor?.call(e.key),
                title: Text(e.value, style: AppText.bodyPrimary),
                trailing: e.key == current
                    ? const Icon(Icons.check, color: AppColors.medBlue)
                    : null,
                onTap: () => Navigator.of(ctx).pop(_Pick(e.key)),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (picked == null || picked.value == current || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await apply(picked.value);
    } catch (e) {
      showApiError(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(groupDetailProvider(group.id).notifier);
    final conv = (ref.watch(conversationsProvider).asData?.value ?? const [])
        .cast<Conversation?>()
        .firstWhere((c) => c?.id == group.conversationId, orElse: () => null);
    final post = group.postPolicy ?? 'all_members';
    final dm = group.memberDmPolicy ?? 'request';
    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel(Strings.groupSettingsLabel),
          ListTile(
            key: const ValueKey('setting-post-policy'),
            leading: const Icon(Icons.campaign_outlined),
            title: const Text(Strings.groupSendMessagesLabel),
            subtitle: Text(
              post == 'admins_only' ? Strings.groupSendAdmins : Strings.groupSendAll,
              style: AppText.caption,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pick<String>(
              context,
              title: Strings.groupSendMessagesLabel,
              options: const {
                'all_members': Strings.groupSendAll,
                'admins_only': Strings.groupSendAdmins,
              },
              current: post,
              keyFor: (v) => ValueKey('post-$v'),
              apply: (v) => notifier.updateGroup(postPolicy: v),
            ),
          ),
          ListTile(
            key: const ValueKey('setting-dm-policy'),
            leading: const Icon(Icons.forum_outlined),
            title: const Text(Strings.groupDmLabel),
            subtitle: Text(_dmLabels[dm] ?? dm, style: AppText.caption),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pick<String>(
              context,
              title: Strings.groupDmLabel,
              options: _dmLabels,
              current: dm,
              keyFor: (v) => ValueKey('dm-$v'),
              apply: (v) => notifier.updateGroup(memberDmPolicy: v),
            ),
          ),
          ListTile(
            key: const ValueKey('setting-disappearing'),
            leading: const Icon(Icons.timer_outlined),
            title: const Text(Strings.groupDisappearingLabel),
            subtitle: Text(
              kDisappearOptions[conv?.disappearAfterSec] ?? 'Off',
              style: AppText.caption,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pick<int?>(
              context,
              title: Strings.groupDisappearingLabel,
              options: kDisappearOptions,
              current: conv?.disappearAfterSec,
              keyFor: (v) => ValueKey('disappear-${v ?? 'off'}'),
              apply: (v) async {
                await ref
                    .read(chatRepositoryProvider)
                    .updateSettings(group.conversationId, disappearAfterSec: v);
                await ref.read(conversationsProvider.notifier).refresh();
              },
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
      ),
    );
  }
}

/// Wraps a picked value so a null option ("Off") survives the sheet pop.
class _Pick<T> {
  final T value;
  const _Pick(this.value);
}

// ---------------------------------------------------------------------------
// Invite links (owner / admin)
// ---------------------------------------------------------------------------

class _InviteLinks extends ConsumerWidget {
  final Group group;
  const _InviteLinks({required this.group});

  static String _expiry(GroupInvite i) {
    final uses = i.maxUses == null
        ? Strings.groupLinkMaxUsesHint
        : '${i.useCount}/${i.maxUses} uses';
    final exp = i.expiresAt == null
        ? Strings.groupLinkExpiryNever
        : _relative(i.expiresAt!);
    return '$uses · ${Strings.groupLinkExpires} $exp';
  }

  static String _relative(DateTime t) {
    final d = t.difference(DateTime.now());
    if (d.isNegative) return 'expired';
    if (d.inDays >= 1) return 'in ${d.inDays}d';
    if (d.inHours >= 1) return 'in ${d.inHours}h';
    return 'in ${d.inMinutes}m';
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final result = await showModalBottomSheet<(int?, Duration?)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => const _CreateLinkSheet(),
    );
    if (result == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final invite = await ref.read(groupInvitesProvider(group.id).notifier).createLink(
            maxUses: result.$1,
            expiresAt: result.$2 == null ? null : DateTime.now().add(result.$2!),
          );
      // The link lands on the clipboard at once; Share stays an explicit tap
      // on the row (a native sheet popping unasked is easy to dismiss by
      // accident, and nothing would tell the admin the link exists).
      if (context.mounted) await _copy(context, invite);
    } catch (e) {
      showApiError(messenger, e);
    }
  }

  Future<void> _share(BuildContext context, GroupInvite invite) async {
    await SharePlus.instance.share(ShareParams(
      text: '${Strings.groupInviteNotificationTitle}: ${group.name}\n${invite.deepLink}',
    ));
  }

  Future<void> _copy(BuildContext context, GroupInvite invite) async {
    await Clipboard.setData(ClipboardData(text: invite.deepLink));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link copied')),
      );
    }
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref, GroupInvite i) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(groupInvitesProvider(group.id).notifier).revoke(i.id);
      messenger.showSnackBar(
        const SnackBar(content: Text(Strings.groupLinkRevoked)),
      );
    } catch (e) {
      showApiError(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(groupInvitesProvider(group.id));
    final links = [
      for (final i in async.asData?.value ?? const <GroupInvite>[]) if (i.isLink) i,
    ];
    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(
            Strings.groupInviteLinksLabel,
            trailing: TextButton.icon(
              key: const ValueKey('link-create'),
              onPressed: () => _create(context, ref),
              icon: const Icon(Icons.add_link, size: 20),
              label: const Text(Strings.groupCreateLink),
            ),
          ),
          if (async.isLoading && !async.hasValue)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.screenHorizontal),
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (links.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenHorizontal,
                0,
                AppSpacing.screenHorizontal,
                AppSpacing.md,
              ),
              child: Text(Strings.groupLinkNone, style: AppText.caption),
            )
          else
            for (final i in links)
              ListTile(
                key: ValueKey('link-${i.id}'),
                leading: const Icon(Icons.link, color: AppColors.medBlue),
                title: Text(
                  i.deepLink,
                  style: AppText.caption.copyWith(color: AppColors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_expiry(i), style: AppText.caption),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: Strings.groupLinkCopy,
                      icon: const Icon(Icons.copy_rounded, size: 20),
                      onPressed: () => _copy(context, i),
                    ),
                    IconButton(
                      tooltip: Strings.groupLinkShare,
                      icon: const Icon(Icons.ios_share_rounded, size: 20),
                      onPressed: () => _share(context, i),
                    ),
                    IconButton(
                      key: ValueKey('link-revoke-${i.id}'),
                      tooltip: Strings.groupLinkRevoke,
                      icon: const Icon(Icons.link_off_rounded,
                          size: 20, color: AppColors.red),
                      onPressed: () => _revoke(context, ref, i),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: AppSpacing.xs),
        ],
      ),
    );
  }
}

/// Max uses (optional number) + expiry preset. Pops `(maxUses, ttl)`.
class _CreateLinkSheet extends StatefulWidget {
  const _CreateLinkSheet();

  @override
  State<_CreateLinkSheet> createState() => _CreateLinkSheetState();
}

class _CreateLinkSheetState extends State<_CreateLinkSheet> {
  final _uses = TextEditingController();
  Duration? _ttl = const Duration(days: 7);

  static const _presets = <(String, Duration?)>[
    (Strings.groupLinkExpiry1Day, Duration(days: 1)),
    (Strings.groupLinkExpiry7Days, Duration(days: 7)),
    (Strings.groupLinkExpiryNever, null),
  ];

  @override
  void dispose() {
    _uses.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, bottom + AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(Strings.groupCreateLink, style: AppText.heading),
          const SizedBox(height: AppSpacing.md),
          AppTextField(
            key: const ValueKey('link-max-uses'),
            controller: _uses,
            label: Strings.groupLinkMaxUses,
            hint: Strings.groupLinkMaxUsesHint,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 4,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(Strings.groupLinkExpires, style: AppText.label),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              for (final p in _presets)
                ChoiceChip(
                  key: ValueKey('link-expiry-${p.$1}'),
                  label: Text(p.$1),
                  selected: _ttl == p.$2,
                  onSelected: (_) => setState(() => _ttl = p.$2),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppButton(
            key: const ValueKey('link-create-confirm'),
            label: Strings.groupCreateLink,
            expand: true,
            onPressed: () {
              final n = int.tryParse(_uses.text.trim());
              Navigator.of(context).pop((n == null || n <= 0 ? null : n, _ttl));
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Members: list, Add (owner/admin), per-member actions
// ---------------------------------------------------------------------------

class _Members extends ConsumerWidget {
  final Group group;
  const _Members({required this.group});

  Widget? _roleBadge(GroupRole role) => switch (role) {
        GroupRole.owner => const AppPill(label: 'Owner', tone: PillTone.brand),
        GroupRole.admin => const AppPill(label: 'Admin', tone: PillTone.brand),
        GroupRole.moderator =>
          const AppPill(label: 'Mod', tone: PillTone.neutral),
        _ => null,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The member list is for members: an invitee sees the count and a hint
    // instead of the 403 the server answers (groups are undiscoverable).
    if (!group.isMember) {
      return _Section(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel(Strings.groupMemberCount(group.memberCount)),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenHorizontal, 0,
                AppSpacing.screenHorizontal, AppSpacing.md,
              ),
              child: Text(
                Strings.groupMembersAfterJoin,
                key: const ValueKey('members-join-hint'),
                style: AppText.caption.copyWith(color: AppColors.gray600),
              ),
            ),
          ],
        ),
      );
    }
    final async = ref.watch(groupMembersProvider(group.id));
    final meId = ref.watch(authProvider).user?.id;
    final manage = group.canManage;
    return _Section(
      child: async.when(
        skipLoadingOnReload: true,
        skipLoadingOnRefresh: true,
        loading: () => const SizedBox(height: 180, child: SkeletonList()),
        error: (e, _) => _InlineError(
          message: ErrorMessages.forApi(e),
          onRetry: () => ref.invalidate(groupMembersProvider(group.id)),
        ),
        data: (members) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel(
              Strings.groupMemberCount(members.length),
              trailing: manage
                  ? TextButton.icon(
                      key: const ValueKey('members-add'),
                      onPressed: () => showGroupAddMembersSheet(
                        context,
                        group: group,
                        existing: {for (final m in members) m.userId},
                      ),
                      icon: const Icon(Icons.person_add_alt_1_outlined, size: 20),
                      label: const Text(Strings.groupAddMembersTitle),
                    )
                  : null,
            ),
            if (members.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
                child: Text(Strings.groupsNoMembers, style: AppText.body),
              ),
            for (final m in members)
              MemberRow(
                key: ValueKey('member-${m.userId}'),
                avatar: DoctorAvatar(
                  initials: m.initials,
                  colorIndex: m.avatarIndex,
                  imageUrl: m.avatarPresignedUrl ?? m.avatarUrl,
                ),
                title: m.userId == meId ? Strings.groupYou : m.fullName,
                subtitle: m.specialty ?? m.headline,
                trailing: _roleBadge(m.role),
                // Your own row opens nothing. Anyone else: the actions sheet
                // when you can act on them, otherwise their profile.
                onTap: m.userId == meId
                    ? null
                    : () => _onMemberTap(context, ref, m, meId),
              ),
          ],
        ),
      ),
    );
  }

  void _onMemberTap(
      BuildContext context, WidgetRef ref, GroupMember m, String? meId) {
    if (!group.isMember || meId == null) {
      context.push(AppRoutes.person(m.userId));
      return;
    }
    showMemberActionsSheet(context, ref, group: group, member: m, meId: meId);
  }
}

/// What the viewer may do to [member]: Message and View profile for anyone;
/// owner adds promote/demote/transfer; owner and admins add remove/ban on
/// those below them (an admin cannot touch the owner or another admin).
Future<void> showMemberActionsSheet(
  BuildContext context,
  WidgetRef ref, {
  required Group group,
  required GroupMember member,
  required String meId,
}) async {
  final isOwner = group.isOwner;
  final isAdmin = group.canManage;
  final targetIsOwner = member.role == GroupRole.owner;
  final targetIsAdmin = member.role == GroupRole.admin;
  final canModerate = isOwner || (isAdmin && !targetIsOwner && !targetIsAdmin);

  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MemberRow(
            avatar: DoctorAvatar(
              initials: member.initials,
              colorIndex: member.avatarIndex,
              imageUrl: member.avatarPresignedUrl ?? member.avatarUrl,
            ),
            title: member.fullName,
            subtitle: member.specialty ?? member.headline,
          ),
          const Divider(height: 1),
          ListTile(
            key: const ValueKey('member-action-message'),
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text(Strings.groupMemberMessage),
            onTap: () => Navigator.pop(ctx, 'message'),
          ),
          ListTile(
            key: const ValueKey('member-action-profile'),
            leading: const Icon(Icons.person_outline),
            title: const Text(Strings.groupMemberViewProfile),
            onTap: () => Navigator.pop(ctx, 'profile'),
          ),
          if (isOwner && !targetIsOwner)
            ListTile(
              key: const ValueKey('member-action-role'),
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: Text(targetIsAdmin
                  ? Strings.groupMemberDemote
                  : Strings.groupMemberPromote),
              onTap: () => Navigator.pop(ctx, targetIsAdmin ? 'demote' : 'promote'),
            ),
          if (isOwner && !targetIsOwner)
            ListTile(
              key: const ValueKey('member-action-transfer'),
              leading: const Icon(Icons.swap_horiz_rounded),
              title: const Text(Strings.groupMemberTransfer),
              onTap: () => Navigator.pop(ctx, 'transfer'),
            ),
          if (canModerate && !targetIsOwner) ...[
            ListTile(
              key: const ValueKey('member-action-remove'),
              leading: const Icon(Icons.person_remove_outlined, color: AppColors.red),
              title: Text(Strings.groupMemberRemove,
                  style: AppText.body.copyWith(color: AppColors.red)),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
            ListTile(
              key: const ValueKey('member-action-ban'),
              leading: const Icon(Icons.block, color: AppColors.red),
              title: Text(Strings.groupMemberBan,
                  style: AppText.body.copyWith(color: AppColors.red)),
              onTap: () => Navigator.pop(ctx, 'ban'),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final notifier = ref.read(groupDetailProvider(group.id).notifier);
  try {
    switch (action) {
      case 'profile':
        context.push(AppRoutes.person(member.userId));
      case 'message':
        final conv = await ref.read(chatRepositoryProvider).createConversation(
              type: ConversationType.direct,
              name: null,
              memberIds: [member.userId],
            );
        if (context.mounted) context.push(AppRoutes.chat(conv.id));
      case 'promote':
        await notifier.changeRole(member.userId, GroupRole.admin);
      case 'demote':
        await notifier.changeRole(member.userId, GroupRole.member);
      case 'remove':
        if (await confirmDialog(context,
            message: Strings.groupRemoveConfirm(member.fullName),
            action: Strings.groupMemberRemove)) {
          await notifier.removeMember(member.userId);
        }
      case 'ban':
        if (await confirmDialog(context,
            message: Strings.groupBanConfirm(member.fullName),
            action: Strings.groupMemberBan)) {
          await notifier.banMember(member.userId);
        }
      case 'transfer':
        if (await confirmDialog(context,
            message: Strings.groupTransferConfirm(member.fullName),
            action: Strings.groupMemberTransfer)) {
          await notifier.transferOwnership(member.userId, meId);
        }
    }
  } catch (e) {
    showApiError(messenger, e);
  }
}

class _InlineError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _InlineError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, style: AppText.caption, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              label: Strings.retry,
              variant: AppButtonVariant.secondary,
              onPressed: onRetry,
            ),
          ],
        ),
      );
}
