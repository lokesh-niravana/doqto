import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/network_profile.dart';
import '../../../state/network_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/inline_connect.dart';
import '../../widgets/person_card_row.dart';
import '../../widgets/primary_button.dart';
import '../home/main_shell.dart';
import '../../../core/utils/async_retry.dart';
import '../../widgets/refresh_feedback.dart';

/// Why a doctor is suggested, in words. The server picks the reason; the app
/// owns the copy.
String suggestionReason(PersonCard p) {
  final place = p.locationLabel;
  final specialty = p.specialty;
  switch (p.reason) {
    case 'colleague':
      return 'In your organization';
    case 'mutual':
      return p.mutualCount == 1
          ? '1 mutual connection'
          : '${p.mutualCount} mutual connections';
    case 'specialty_nearby':
      return [specialty, place].whereType<String>().join(' · ');
    case 'specialty':
      return specialty ?? 'Same specialty';
    case 'nearby':
      return place == null ? 'Near you' : 'Near you · $place';
    case 'new_member':
      return 'New to Doqto';
  }
  return specialty ?? p.headline ?? '';
}

/// One suggested doctor: tap for the profile, Connect to invite, × to hide.
class SuggestionRow extends ConsumerWidget {
  const SuggestionRow({super.key, required this.person});
  final PersonCard person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InlineConnect(userId: person.id, compact: true),
        IconButton(
          tooltip: 'Hide ${person.fullName}',
          icon: Icon(Icons.close, size: 20, color: AppColors.gray400),
          onPressed: () async {
            try {
              await ref.read(suggestionsProvider.notifier).dismiss(person.id);
            } catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(ErrorMessages.forApi(e)),
                backgroundColor: AppColors.red,
              ));
            }
          },
        ),
      ],
    );
    void open() => context.push(AppRoutes.person(person.id));
    // Past about 1.3x the pill and the hide button left three characters of
    // the name: they move to a line of their own under it.
    final large = MediaQuery.textScalerOf(context).scale(100) / 100 > 1.3;
    if (!large) {
      return PersonCardRow(
        person: person,
        subtitle: suggestionReason(person),
        onTap: open,
        trailing: controls,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PersonCardRow(
          person: person,
          subtitle: suggestionReason(person),
          onTap: open,
          trailing: const SizedBox.shrink(),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
            child: controls,
          ),
        ),
      ],
    );
  }
}

/// See all: every suggestion (up to the server's page).
class SuggestionsScreen extends ConsumerWidget {
  const SuggestionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(suggestionsProvider);
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text('Recommended for you')),
      body: RefreshIndicator(
        onRefresh: () => refreshWithFeedback(
          context,
          () => ref.read(suggestionsProvider.notifier).refresh(rethrowOnError: true),
        ),
        child: async.whenRetrying(
          skipLoadingOnRefresh: true,
          loading: () => const SkeletonList(),
          // refresh() keeps the old state on failure, so Retry rebuilds the
          // provider instead.
          error: (e, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi_off_rounded,
                        size: 40, color: AppColors.textMuted),
                    const SizedBox(height: AppSpacing.md),
                    Semantics(
                      container: true,
                      liveRegion: true,
                      child: Text(ErrorMessages.forApi(e),
                          style: AppText.caption, textAlign: TextAlign.center),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      key: const ValueKey('suggestions-retry'),
                      label: Strings.retry,
                      icon: Icons.refresh_rounded,
                      onPressed: () => ref.invalidate(suggestionsProvider),
                    ),
                  ],
                ),
              ),
            ],
          ),
          data: (people) => people.isEmpty
              ? ListView(children: [
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Text('No suggestions right now.',
                        style: AppText.body, textAlign: TextAlign.center),
                  ),
                ])
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.only(
                    top: AppSpacing.sm,
                    bottom: MediaQuery.paddingOf(context).bottom + kMicButtonRise + AppSpacing.xl,
                  ),
                  itemCount: people.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.screenHorizontal),
                    child: SuggestionRow(person: people[i]),
                  ),
                ),
        ),
      ),
    );
  }
}
