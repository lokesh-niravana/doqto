import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../state/people_search_state.dart';
import '../../widgets/app_pill.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/person_card_row.dart';
import '../../widgets/inline_connect.dart';
import '../../widgets/search_bar.dart';

/// People search (M3). Opens on a browsable directory and narrows as you
/// type; both modes page in as you scroll. Row tap opens the addressable
/// profile; the trailing button does a lightweight inline optimistic invite
/// (see [_InlineConnect]) so users can connect without a round-trip through
/// the profile screen.
class PeopleSearchScreen extends ConsumerWidget {
  const PeopleSearchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(peopleSearchProvider);
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.netDiscoverPeople)),
      body: Column(
        children: [
          AppSearchBar(
            hint: Strings.netSearchPeopleHint,
            onChanged: (q) => ref.read(peopleSearchProvider.notifier).search(q),
          ),
          Expanded(child: _Body(state: state)),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final PeopleSearchState state;
  const _Body({required this.state});

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      PeopleSearchLoading() => const SkeletonList(),
      PeopleSearchError(:final error) => _Message(
          icon: Icons.wifi_off_rounded,
          text: ErrorMessages.forApi(error),
        ),
      PeopleSearchResults(:final people) => people.isEmpty
          ? const _Message(
              icon: Icons.search_off_rounded,
              text: Strings.netEmptySearch,
            )
          : _ResultsList(results: state as PeopleSearchResults),
    };
  }
}

/// Infinite-scroll list. Asks for the next page once the viewport is within
/// [_loadMoreExtent] of the end, so the spinner is rarely seen.
class _ResultsList extends ConsumerStatefulWidget {
  final PeopleSearchResults results;
  const _ResultsList({required this.results});

  @override
  ConsumerState<_ResultsList> createState() => _ResultsListState();
}

class _ResultsListState extends ConsumerState<_ResultsList> {
  static const double _loadMoreExtent = 600;
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (position.pixels >= position.maxScrollExtent - _loadMoreExtent) {
      // The notifier ignores this while a page is in flight or the list is
      // exhausted, so firing on every frame of a fast scroll is harmless.
      ref.read(peopleSearchProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = widget.results.people;
    return RefreshIndicator(
      onRefresh: () => ref.read(peopleSearchProvider.notifier).refresh(),
      child: ListView.builder(
        controller: _controller,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          top: AppSpacing.sm,
          bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
        ),
        itemCount: people.length + (widget.results.loadingMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= people.length) {
            return const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final p = people[i];
          return FadeSlideIn.staggered(
            i,
            PersonCardRow(
              person: p,
              onTap: () => context.push(AppRoutes.person(p.id)),
              trailing: p.degree == ConnectionDegree.first
                  ? DegreeBadge.forDegree(p.degree)
                  : InlineConnect(userId: p.id),
            ),
          );
        },
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Message({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.gray400),
            const SizedBox(height: AppSpacing.md),
            Text(text, style: AppText.body, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
