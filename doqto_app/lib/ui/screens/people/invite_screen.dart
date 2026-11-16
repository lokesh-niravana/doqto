import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
import '../../../data/models/network_profile.dart';
import '../../../state/auth_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/inline_connect.dart';
import '../../widgets/member_row.dart';
import '../../widgets/search_bar.dart';

/// Opens the phone's share sheet. A provider so tests can see what was shared.
final shareTextProvider =
    Provider<Future<void> Function(String text, Rect? origin)>(
  (ref) => (text, origin) => SharePlus.instance
      .share(ShareParams(text: text, sharePositionOrigin: origin)),
);

const _states = [
  'AL', 'AK', 'AZ', 'AR', 'CA', 'CO', 'CT', 'DE', 'DC', 'FL', 'GA', 'HI', 'ID', //
  'IL', 'IN', 'IA', 'KS', 'KY', 'LA', 'ME', 'MD', 'MA', 'MI', 'MN', 'MS', 'MO',
  'MT', 'NE', 'NV', 'NH', 'NJ', 'NM', 'NY', 'NC', 'ND', 'OH', 'OK', 'OR', 'PA',
  'PR', 'RI', 'SC', 'SD', 'TN', 'TX', 'UT', 'VT', 'VA', 'WA', 'WV', 'WI', 'WY',
];

/// Invite a colleague: search the NPI Registry. Doctors already on Doqto get
/// Message / Requested / Connect; everyone else gets Invite, which remembers
/// the NPI (so they're connected to us when they register) and opens the
/// share sheet.
class InviteScreen extends ConsumerStatefulWidget {
  final String initialQuery;
  const InviteScreen({super.key, this.initialQuery = ''});

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  late String _query = widget.initialQuery;
  String? _state;
  Future<List<NpiHit>>? _results;

  @override
  void initState() {
    super.initState();
    // Most colleagues practise nearby; "Any" is one tap away.
    final mine = ref.read(authProvider).user?.state?.toUpperCase();
    if (_states.contains(mine)) _state = mine;
    _search();
  }

  void _search() {
    final q = _query.trim();
    // FutureBuilder drops a stale future when this one replaces it.
    final results = q.length < 2
        ? null
        : ref.read(networkRepositoryProvider).npiLookup(q, state: _state);
    setState(() {
      _results = results;
    });
  }

  Rect? _origin(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    return box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _invite(BuildContext rowContext, NpiHit? hit) async {
    final origin = _origin(rowContext);
    if (hit != null) {
      // Best effort: the share still goes out if this fails; only the
      // auto-connect on sign-up is lost.
      ref.read(networkRepositoryProvider).recordInvite(hit.npi).ignore();
    }
    await ref.read(shareTextProvider)(Strings.inviteMessage(hit?.greeting), origin);
  }

  Future<void> _message(String userId) async {
    try {
      final conv = await ref.read(chatRepositoryProvider).createConversation(
            type: ConversationType.direct,
            name: null,
            memberIds: [userId],
          );
      if (mounted) openConversation(context, conv.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.inviteTitle)),
      body: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: AppSearchBar(
                  hint: Strings.inviteSearchHint,
                  initialValue: widget.initialQuery,
                  debounce: const Duration(milliseconds: 400),
                  onChanged: (q) {
                    _query = q;
                    _search();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.lg),
                child: DropdownButton<String?>(
                  value: _state,
                  hint: const Text(Strings.inviteStateLabel),
                  underline: const SizedBox.shrink(),
                  borderRadius: AppRadii.rMd,
                  menuMaxHeight: 360,
                  items: [
                    const DropdownMenuItem(value: null, child: Text(Strings.inviteAnyState)),
                    for (final s in _states) DropdownMenuItem(value: s, child: Text(s)),
                  ],
                  onChanged: (s) {
                    _state = s;
                    _search();
                  },
                ),
              ),
            ],
          ),
          Expanded(
            child: FutureBuilder<List<NpiHit>>(
              future: _results,
              builder: (context, snap) {
                final List<Widget> top;
                if (_results == null) {
                  top = [_Note(Strings.inviteIntro)];
                } else if (snap.connectionState != ConnectionState.done) {
                  return const SkeletonList();
                } else if (snap.hasError) {
                  top = [_Note(ErrorMessages.forApi(snap.error!))];
                } else if (snap.data!.isEmpty) {
                  top = [_Note(Strings.inviteNoResults)];
                } else {
                  top = [
                    _Note(Strings.inviteResultCount(snap.data!.length)),
                    for (final hit in snap.data!) _row(hit),
                  ];
                }
                return ListView(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
                  ),
                  children: [...top, _CantFind(onShare: (c) => _invite(c, null))],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(NpiHit hit) {
    final initials = hit.name
        .split(',')
        .first
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0])
        .take(2)
        .join();
    final userId = hit.userId;
    return MemberRow(
      avatar: DoctorAvatar(
        initials: initials,
        colorIndex: hit.npi.hashCode,
        size: AvatarSize.lg,
      ),
      title: hit.name,
      subtitle: [hit.specialty, hit.location].whereType<String>().join(' · '),
      onTap: userId == null ? null : () => context.push(AppRoutes.person(userId)),
      trailing: switch (hit.status) {
        NpiStatus.message => _Pill(
            label: Strings.netMessage,
            onPressed: () => _message(userId!),
          ),
        NpiStatus.requested => const _Pill(label: Strings.inviteRequested),
        NpiStatus.connect => InlineConnect(userId: userId!, compact: true),
        NpiStatus.invite => Builder(
            builder: (c) => _Pill(
              label: Strings.inviteButton,
              icon: Icons.ios_share,
              accent: true,
              onPressed: () => _invite(c, hit),
            ),
          ),
      },
    );
  }
}

/// The compact pill shape InlineConnect uses, for the other three states.
class _Pill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool accent;
  final VoidCallback? onPressed;
  const _Pill({required this.label, this.icon, this.accent = false, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      minimumSize: const Size(0, 34),
      backgroundColor: accent ? AppColors.medBlueLight : AppColors.white,
      foregroundColor: accent ? AppColors.medBlue : AppColors.medBlueDark,
      disabledBackgroundColor: AppColors.gray100,
      disabledForegroundColor: AppColors.gray600,
      shape: StadiumBorder(
        side: onPressed == null
            ? BorderSide.none
            : BorderSide(color: accent ? AppColors.medBlue : AppColors.border),
      ),
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
    );
    return SizedBox(
      height: 34,
      child: icon == null
          ? TextButton(onPressed: onPressed, style: style, child: Text(label))
          : TextButton.icon(
              onPressed: onPressed,
              style: style,
              icon: Icon(icon, size: 16),
              label: Text(label),
            ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
        child: Text(text, style: AppText.caption.copyWith(color: AppColors.textSecondary)),
      );
}

class _CantFind extends StatelessWidget {
  final void Function(BuildContext) onShare;
  const _CantFind({required this.onShare});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.rLg,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(Strings.inviteCantFind, style: AppText.heading.copyWith(fontSize: 15)),
          const SizedBox(height: AppSpacing.xs),
          Text(Strings.inviteCantFindBody,
              style: AppText.caption.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: AppSpacing.md),
          Builder(
            builder: (c) => OutlinedButton.icon(
              onPressed: () => onShare(c),
              icon: const Icon(Icons.link, size: 18),
              label: const Text(Strings.inviteShareLink),
            ),
          ),
        ],
      ),
    );
  }
}
