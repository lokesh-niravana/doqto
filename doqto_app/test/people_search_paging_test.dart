import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/repositories/network_repository.dart';
import 'package:doqto_app/state/people_search_state.dart';

/// Serves 25 people in pages of 10 through an offset cursor, exactly like the
/// backend's `/people/search` (which omits `q` to browse).
class _FakeNetworkRepository extends NetworkRepository {
  final List<String> calls = [];

  /// Fail every request for a page after the first.
  bool failMore = false;
  _FakeNetworkRepository() : super(ApiClient());

  static PersonCard _card(String name) => PersonCard.fromJson({
        'id': name,
        'full_name': name,
        'degree': '3rd',
      });

  @override
  Future<CursorPage<PersonCard>> searchPeople({
    String? q,
    String? specialty,
    String? state,
    String? degree,
    String? cursor,
    int? limit,
  }) async {
    calls.add('q=$q cursor=$cursor');
    if (failMore && cursor != null) throw Exception('offline');
    const total = 25;
    const pageSize = 10;
    final offset = int.tryParse(cursor ?? '0') ?? 0;
    final prefix = q ?? 'all';
    final end = (offset + pageSize).clamp(0, total);
    final page = [for (var i = offset; i < end; i++) _card('$prefix-$i')];
    return CursorPage(page, end < total ? '$end' : null);
  }
}

Future<PeopleSearchResults> _settled(ProviderContainer c) async {
  // build() kicks off the browse fetch in a microtask.
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
    final s = c.read(peopleSearchProvider);
    if (s is PeopleSearchResults) return s;
  }
  throw StateError('never settled: ${c.read(peopleSearchProvider)}');
}

void main() {
  late _FakeNetworkRepository fake;
  late ProviderContainer container;

  setUp(() {
    fake = _FakeNetworkRepository();
    container = ProviderContainer(
      overrides: [networkRepositoryProvider.overrideWithValue(fake)],
    );
  });
  tearDown(() => container.dispose());

  test('browses the directory before anything is typed', () async {
    final s = await _settled(container);

    expect(s.query, isEmpty);
    expect(s.people, hasLength(10));
    expect(s.hasMore, isTrue);
    // No `q` on the wire — that is what makes it a browse.
    expect(fake.calls.single, 'q=null cursor=null');
  });

  test('loadMore appends the next page and stops at the end', () async {
    await _settled(container);
    final notifier = container.read(peopleSearchProvider.notifier);

    await notifier.loadMore();
    var s = container.read(peopleSearchProvider) as PeopleSearchResults;
    expect(s.people, hasLength(20));
    expect(s.people.first.id, 'all-0'); // earlier page kept, not replaced
    expect(s.hasMore, isTrue);

    await notifier.loadMore();
    s = container.read(peopleSearchProvider) as PeopleSearchResults;
    expect(s.people, hasLength(25));
    expect(s.hasMore, isFalse);

    // Exhausted: further scrolling must not hit the network again.
    final before = fake.calls.length;
    await notifier.loadMore();
    expect(fake.calls, hasLength(before));
  });

  test('searching resets paging and pages the query too', () async {
    await _settled(container);
    final notifier = container.read(peopleSearchProvider.notifier);
    await notifier.loadMore();

    await notifier.search('cardio');
    var s = container.read(peopleSearchProvider) as PeopleSearchResults;
    expect(s.query, 'cardio');
    expect(s.people, hasLength(10)); // reset, not appended to the browse list
    expect(s.people.first.id, 'cardio-0');

    await notifier.loadMore();
    s = container.read(peopleSearchProvider) as PeopleSearchResults;
    expect(s.people, hasLength(20));
    expect(s.people.last.id, 'cardio-19');
    expect(fake.calls.last, 'q=cardio cursor=10');
  });

  test('a failed next page is kept as an error until Retry, not swallowed', () async {
    await _settled(container);
    final n = container.read(peopleSearchProvider.notifier);
    fake.failMore = true;
    await n.loadMore();
    var s = container.read(peopleSearchProvider) as PeopleSearchResults;
    expect(s.moreError, isNotNull);
    expect(s.loadingMore, isFalse);
    expect(s.people, hasLength(10), reason: 'rows on screen stay');
    expect(s.hasMore, isTrue);

    // Scrolling does not refire a page that just failed.
    final before = fake.calls.length;
    await n.loadMore();
    expect(fake.calls.length, before);

    // Retry clears the error and lands the page.
    fake.failMore = false;
    await n.loadMore(retry: true);
    s = container.read(peopleSearchProvider) as PeopleSearchResults;
    expect(s.moreError, isNull);
    expect(s.people, hasLength(20));
  });
}
