import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../data/models/network_profile.dart';

/// One render state for the people-search screen.
sealed class PeopleSearchState {
  const PeopleSearchState();
}

/// The first page is in flight. [query] is empty while browsing.
class PeopleSearchLoading extends PeopleSearchState {
  final String query;
  const PeopleSearchLoading(this.query);
}

/// A page of people. [query] is empty when this is the browse list.
/// [hasMore] drives the infinite scroll; [loadingMore] the footer spinner.
class PeopleSearchResults extends PeopleSearchState {
  final String query;
  final List<PersonCard> people;
  final bool hasMore;
  final bool loadingMore;

  /// Why the next page failed, while the rows already loaded stay on
  /// screen. The footer shows it with a Retry; scrolling does not refire.
  final Object? moreError;

  const PeopleSearchResults(
    this.query,
    this.people, {
    this.hasMore = false,
    this.loadingMore = false,
    this.moreError,
  });

  /// [moreError] is not carried over: each copy states it afresh.
  PeopleSearchResults copyWith({
    List<PersonCard>? people,
    bool? hasMore,
    bool? loadingMore,
    Object? moreError,
  }) =>
      PeopleSearchResults(
        query,
        people ?? this.people,
        hasMore: hasMore ?? this.hasMore,
        loadingMore: loadingMore ?? this.loadingMore,
        moreError: moreError,
      );
}

/// The page failed.
class PeopleSearchError extends PeopleSearchState {
  final String query;
  final Object error;
  const PeopleSearchError(this.query, this.error);
}

/// People search AND the default browse list — one cursor-paginated endpoint
/// that simply omits `q` when nothing is typed, so both scroll the same way.
///
/// Latest-wins guard: every [search] bumps a monotonic token, so a slow
/// response whose token is stale is dropped and the list never flashes results
/// from an earlier query. Debounce lives in the search bar.
class PeopleSearchNotifier extends Notifier<PeopleSearchState> {
  int _token = 0;
  String _query = '';
  String? _cursor;

  @override
  PeopleSearchState build() {
    // Browse straight away — an empty screen tells a doctor nothing about who
    // is on the platform.
    Future.microtask(() => search(''));
    return const PeopleSearchLoading('');
  }

  Future<void> search(String rawQuery) async {
    final query = rawQuery.trim();
    final token = ++_token; // newest wins
    _query = query;
    _cursor = null;
    state = PeopleSearchLoading(query);
    try {
      final page = await ref
          .read(networkRepositoryProvider)
          .searchPeople(q: query.isEmpty ? null : query);
      if (token != _token) return; // a newer query superseded us
      _cursor = page.nextCursor;
      state = PeopleSearchResults(
        query,
        page.data,
        hasMore: page.nextCursor != null,
      );
    } catch (e) {
      if (token != _token) return;
      state = PeopleSearchError(query, e);
    }
  }

  /// Appends the next page. No-op while a page is in flight, at the end of the
  /// list, or once the query has moved on. After a failed page it waits for
  /// the footer's Retry ([retry] true) instead of refiring on every scroll.
  Future<void> loadMore({bool retry = false}) async {
    final current = state;
    if (current is! PeopleSearchResults) return;
    if (current.loadingMore || !current.hasMore || _cursor == null) return;
    if (current.moreError != null && !retry) return;

    final token = _token;
    final cursor = _cursor;
    state = current.copyWith(loadingMore: true);
    try {
      final page = await ref.read(networkRepositoryProvider).searchPeople(
            q: _query.isEmpty ? null : _query,
            cursor: cursor,
          );
      if (token != _token) return; // the query changed under us
      _cursor = page.nextCursor;
      state = current.copyWith(
        people: [...current.people, ...page.data],
        hasMore: page.nextCursor != null,
        loadingMore: false,
      );
    } catch (e) {
      if (token != _token) return;
      // Keep what is already on screen, and say the next page failed.
      state = current.copyWith(loadingMore: false, moreError: e);
    }
  }

  Future<void> refresh() => search(_query);
}

final peopleSearchProvider =
    NotifierProvider<PeopleSearchNotifier, PeopleSearchState>(
        PeopleSearchNotifier.new);
