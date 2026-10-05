import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
    return PersonCardRow(
      person: person,
      subtitle: suggestionReason(person),
      onTap: () => context.push(AppRoutes.person(person.id)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InlineConnect(userId: person.id, compact: true),
          IconButton(
            tooltip: 'Hide ${person.fullName}',
            icon: const Icon(Icons.close, size: 20, color: AppColors.gray400),
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
      ),
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
        onRefresh: () => ref.read(suggestionsProvider.notifier).refresh(),
        child: async.when(
          skipLoadingOnRefresh: true,
          loading: () => const SkeletonList(),
          error: (e, _) => ListView(children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Text(ErrorMessages.forApi(e),
                  style: AppText.body, textAlign: TextAlign.center),
            ),
          ]),
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
                    bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
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
