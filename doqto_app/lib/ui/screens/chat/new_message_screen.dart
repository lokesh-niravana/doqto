import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../state/auth_state.dart';
import '../../../state/network_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/search_bar.dart';

/// "Start a conversation": pick a person, land in your chat with them. Like
/// WhatsApp's new chat — connections first, then colleagues, one row per
/// person. A direct chat needs no organization; only "New group" does.
class NewMessageScreen extends ConsumerStatefulWidget {
  const NewMessageScreen({super.key});

  @override
  ConsumerState<NewMessageScreen> createState() => _NewMessageScreenState();
}

typedef _Person = ({String id, String name, String sub, String initials, String? image});

class _NewMessageScreenState extends ConsumerState<NewMessageScreen> {
  String _query = '';
  String? _opening;

  bool _match(_Person p) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty || '${p.name} ${p.sub}'.toLowerCase().contains(q);
  }

  Future<void> _open(_Person p) async {
    if (_opening != null) return;
    setState(() => _opening = p.id);
    try {
      // The server hands back the existing chat if there is one.
      final conv = await ref.read(chatRepositoryProvider).createConversation(
            type: ConversationType.direct,
            name: null,
            memberIds: [p.id],
          );
      if (!mounted) return;
      // Replace the picker: back from the chat returns to Chats.
      context.pushReplacement(AppRoutes.chat(conv.id));
    } catch (e) {
      if (!mounted) return;
      setState(() => _opening = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final meId = ref.watch(authProvider).user?.id;
    final org = ref.watch(orgProvider).current;
    final connectionsAsync = ref.watch(connectionsProvider);
    final membersAsync = org == null ? null : ref.watch(orgMembersProvider(org.id));

    final List<_Person> connections = [
      for (final c in connectionsAsync.value ?? const [])
        (
          id: c.id,
          name: c.fullName,
          sub: [c.specialty, c.locationLabel].whereType<String>().join(' · '),
          initials: c.initials,
          image: c.avatarPresignedUrl,
        ),
    ];
    final connected = {for (final c in connections) c.id};
    // Someone who is both shows once, under connections.
    final List<_Person> colleagues = [
      for (final m in membersAsync?.value ?? const [])
        if (m.id != meId && !connected.contains(m.id))
          (
            id: m.id,
            name: m.fullName,
            sub: m.specialty ?? '',
            initials: m.initials,
            image: m.avatarPresignedUrl,
          ),
    ];
    final shownConnections = connections.where(_match).toList();
    final shownColleagues = colleagues.where(_match).toList();
    final total = connections.length + colleagues.length;
    final searching = _query.trim().isNotEmpty;
    final loading = connectionsAsync.isLoading && !connectionsAsync.hasValue;
    final canGroup = org?.status == OrgStatus.active;

    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('New message'),
            if (total > 0)
              Text(
                total == 1 ? '1 person you can message' : '$total people you can message',
                style: AppText.caption,
              ),
          ],
        ),
      ),
      body: loading
          ? const SkeletonList()
          : connectionsAsync.hasError && total == 0
              ? _Message(
                  title: 'Couldn’t load your contacts',
                  body: ErrorMessages.forApi(connectionsAsync.error!),
                  action: 'Retry',
                  onAction: () => ref.invalidate(connectionsProvider),
                )
              : total == 0
                  ? _Message(
                      title: 'No one to message yet',
                      body: 'Connect with doctors you know. Once they accept, '
                          'you can message them here.',
                      action: 'Find doctors on Doqto',
                      onAction: () => context.push(AppRoutes.peopleSearch),
                      link: org == null ? 'Join or create an organization' : null,
                      onLink: () => context.go(AppRoutes.myOrg),
                    )
                  : Column(
                      children: [
                        AppSearchBar(
                          hint: 'Search name or specialty',
                          onChanged: (q) => setState(() => _query = q),
                        ),
                        Expanded(
                          child: ListView(
                            padding: EdgeInsets.only(
                              bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
                            ),
                            children: [
                              if (!searching) ...[
                                if (canGroup)
                                  _ActionRow(
                                    icon: Icons.group_add_outlined,
                                    filled: true,
                                    title: 'New group',
                                    onTap: () => context.push(AppRoutes.groupsCreate),
                                  ),
                                _ActionRow(
                                  icon: Icons.person_search_outlined,
                                  title: 'Find doctors on Doqto',
                                  subtitle: 'Search by name, NPI or hospital',
                                  onTap: () => context.push(AppRoutes.peopleSearch),
                                ),
                              ],
                              if (shownConnections.isNotEmpty) ...[
                                const _Header('CONNECTIONS'),
                                for (final p in shownConnections) _row(p),
                              ],
                              if (shownColleagues.isNotEmpty) ...[
                                _Header('COLLEAGUES · ${org!.name.toUpperCase()}'),
                                for (final p in shownColleagues) _row(p),
                              ],
                              if (searching && shownConnections.isEmpty && shownColleagues.isEmpty)
                                _Message(
                                  title: 'No one called “${_query.trim()}” yet',
                                  body: 'They may be on Doqto but not connected with you.',
                                  action: 'Search all of Doqto',
                                  onAction: () => context.push(AppRoutes.peopleSearch),
                                ),
                              if (!searching && org == null)
                                _OrgCard(onTap: () => context.go(AppRoutes.myOrg)),
                            ],
                          ),
                        ),
                      ],
                    ),
    );
  }

  Widget _row(_Person p) => ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenHorizontal,
          vertical: AppSpacing.xs,
        ),
        leading: DoctorAvatar(
          initials: p.initials,
          colorIndex: p.id.hashCode,
          imageUrl: p.image,
        ),
        title: Text(p.name, style: AppText.heading, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: p.sub.isEmpty
            ? null
            : Text(p.sub, style: AppText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: _opening == p.id
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        onTap: () => _open(p),
      );
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenHorizontal,
          AppSpacing.lg,
          AppSpacing.screenHorizontal,
          AppSpacing.xs,
        ),
        child: Text(text, style: AppText.label),
      );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.filled = false,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenHorizontal,
          vertical: AppSpacing.xs,
        ),
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: filled ? AppColors.medBlue : AppColors.medBlueLight,
          foregroundColor: filled ? AppColors.white : AppColors.medBlue,
          child: Icon(icon),
        ),
        title: Text(title, style: AppText.heading),
        subtitle: subtitle == null ? null : Text(subtitle!, style: AppText.caption),
        onTap: onTap,
      );
}

class _OrgCard extends StatelessWidget {
  const _OrgCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenHorizontal,
          AppSpacing.xl,
          AppSpacing.screenHorizontal,
          0,
        ),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.gray200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Want group chats with your team?', style: AppText.heading),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Groups come with a verified organization. Your colleagues '
                'will show up here too.',
                style: AppText.body,
              ),
              TextButton(
                onPressed: onTap,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: AppColors.medBlue,
                ),
                child: const Text('Join or create an organization'),
              ),
            ],
          ),
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.title,
    required this.body,
    required this.action,
    required this.onAction,
    this.link,
    this.onLink,
  });
  final String title;
  final String body;
  final String action;
  final VoidCallback onAction;
  final String? link;
  final VoidCallback? onLink;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenHorizontal,
          vertical: AppSpacing.xxl,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, style: AppText.heading, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.sm),
            Text(body, style: AppText.body, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.lg),
            AppButton(label: action, onPressed: onAction),
            if (link != null)
              TextButton(
                onPressed: onLink,
                style: TextButton.styleFrom(foregroundColor: AppColors.medBlue),
                child: Text(link!),
              ),
          ],
        ),
      );
}
