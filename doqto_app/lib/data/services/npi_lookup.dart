import 'dart:convert';

import 'package:dio/dio.dart';

/// Prefill from the public CMS NPI Registry — see `docs/npi-lookup.md`.
///
/// This is a *convenience*, never a trust boundary: everything it fills stays
/// editable, and every failure is silent. Authoritative NPI verification is a
/// backend concern.
///
/// Deliberately uses a bare [Dio], not `ApiClient`: nppes.cms.hhs.gov is a
/// third party and must never see our base URL, our bearer token, or our
/// 401-refresh interceptor.

/// One individual provider, flattened to what the registration screen shows.
class NpiMatch {
  final String npi;

  /// Registry name, title-cased, with credential appended — "Vimal Nanavati, M.D."
  final String displayName;

  /// The same name split, for "Use these details". Null on hand-built matches.
  final String? firstName;
  final String? lastName;

  /// Primary practice address, split for display. Null when the registry has
  /// no usable address.
  final String? addressLine;
  final String? cityStateZip;

  /// Persisted on the user record.
  final String? city;
  final String? state;

  /// Primary taxonomy description, verbatim from the registry.
  final String? taxonomy;

  const NpiMatch({
    required this.npi,
    required this.displayName,
    this.firstName,
    this.lastName,
    this.addressLine,
    this.cityStateZip,
    this.city,
    this.state,
    this.taxonomy,
  });

  factory NpiMatch.fromResult(Map<String, dynamic> r) {
    final basic = (r['basic'] as Map?)?.cast<String, dynamic>() ?? const {};
    final firstName = titleCase((basic['first_name'] ?? '') as String);
    final lastName = titleCase((basic['last_name'] ?? '') as String);
    final name = [firstName, lastName].where((p) => p.isNotEmpty).join(' ');
    // Credentials ("M.D.", "DO") are already correctly cased — never touch them.
    final credential = ((basic['credential'] ?? '') as String).trim();

    final addresses = ((r['addresses'] as List?) ?? const [])
        .whereType<Map>()
        .map((a) => a.cast<String, dynamic>())
        .toList();
    // The registry's own "Primary Practice Address" column is the LOCATION
    // entry. `practiceLocations[]` holds *secondary* sites — ignore it.
    final addr =
        _firstOrNull(addresses, (a) => a['address_purpose'] == 'LOCATION') ??
        _firstOrNull(addresses, (a) => a['address_purpose'] == 'MAILING');

    final taxonomies = ((r['taxonomies'] as List?) ?? const [])
        .whereType<Map>()
        .map((t) => t.cast<String, dynamic>())
        .toList();
    final tax = _firstOrNull(taxonomies, (t) => t['primary'] == true) ??
        _firstOrNull(taxonomies, (_) => true);
    final taxDesc = ((tax?['desc'] ?? '') as String).trim();

    return NpiMatch(
      npi: (r['number'] ?? '').toString(),
      displayName: credential.isEmpty ? name : '$name, $credential',
      firstName: _orNull(firstName),
      lastName: _orNull(lastName),
      addressLine: addr == null ? null : _street(addr),
      cityStateZip: addr == null ? null : _cityStateZip(addr),
      city: addr == null ? null : _orNull(titleCase((addr['city'] ?? '') as String)),
      state: addr == null ? null : _orNull(((addr['state'] ?? '') as String).trim()),
      taxonomy: taxDesc.isEmpty ? null : taxDesc,
    );
  }

  static String? _orNull(String s) => s.isEmpty ? null : s;

  static Map<String, dynamic>? _firstOrNull(
    List<Map<String, dynamic>> items,
    bool Function(Map<String, dynamic>) test,
  ) {
    for (final item in items) {
      if (test(item)) return item;
    }
    return null;
  }

  static String? _street(Map<String, dynamic> a) => _orNull(
    [
      titleCase((a['address_1'] ?? '') as String),
      titleCase((a['address_2'] ?? '') as String),
    ].where((s) => s.isNotEmpty).join(', '),
  );

  static String? _cityStateZip(Map<String, dynamic> a) {
    final city = titleCase((a['city'] ?? '') as String);
    final state = ((a['state'] ?? '') as String).trim();
    final zip = formatZip((a['postal_code'] ?? '') as String);
    final left = [city, state].where((s) => s.isNotEmpty).join(', ');
    return _orNull([left, zip].where((s) => s.isNotEmpty).join(' '));
  }

  /// The registry SHOUTS every name and address. Lower-case, then capitalise
  /// after a start, space, hyphen, apostrophe or slash so O'BRIEN → O'Brien.
  static String titleCase(String s) => s.trim().toLowerCase().replaceAllMapped(
    RegExp(r"(^|[\s\-'/])([a-z])"),
    (m) => '${m[1]}${m[2]!.toUpperCase()}',
  );

  /// ZIPs arrive as 9 unpunctuated digits: 919022444 → 91902-2444.
  static String formatZip(String raw) {
    final z = raw.trim();
    if (z.length == 9 && !z.contains('-')) return '${z.substring(0, 5)}-${z.substring(5)}';
    return z;
  }
}

enum NpiLookupOutcome {
  /// Exactly one provider — safe to prefill.
  matched,

  /// Two or more share the name — prefill nothing, ask for the NPI.
  ambiguous,

  /// Nobody, or the lookup failed. Both are silent.
  none,
}

class NpiLookupResult {
  final NpiLookupOutcome outcome;

  /// Non-null iff [outcome] is [NpiLookupOutcome.matched].
  final NpiMatch? match;

  const NpiLookupResult.matched(NpiMatch this.match) : outcome = NpiLookupOutcome.matched;
  const NpiLookupResult.ambiguous() : outcome = NpiLookupOutcome.ambiguous, match = null;
  const NpiLookupResult.none() : outcome = NpiLookupOutcome.none, match = null;
}

class NpiLookup {
  static const String baseUrl = 'https://npiregistry.cms.hhs.gov/api/';

  final Dio _dio;

  // ponytail: session-lifetime memo, no disk cache. Registration is a
  // one-screen, one-time flow — nothing survives long enough to be worth
  // persisting.
  final Map<String, NpiLookupResult> _cache = {};

  NpiLookup({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
            ),
          );

  Future<NpiLookupResult> byName(String first, String last) =>
      _query('name:${first.toLowerCase()}|${last.toLowerCase()}', {
        'first_name': first,
        'last_name': last,
        // Individuals only — NPI-2 is organisations, which have no name parts.
        'enumeration_type': 'NPI-1',
        // `result_count` is capped by `limit`, so 2 is exactly enough to tell
        // "one match" from "more than one". A larger limit buys nothing.
        'limit': '2',
      });

  Future<NpiLookupResult> byNumber(String npi) => _query('npi:$npi', {'number': npi});

  Future<NpiLookupResult> _query(String key, Map<String, String> params) async {
    final cached = _cache[key];
    if (cached != null) return cached;
    try {
      final resp = await _dio.get(baseUrl, queryParameters: {'version': '2.1', ...params});
      final result = parseResponse(resp.data);
      _cache[key] = result;
      return result;
    } catch (_) {
      // Never cache a failure — the next attempt may reach CMS.
      return const NpiLookupResult.none();
    }
  }

  /// Visible for testing. CMS returns HTTP 200 with an `Errors` array (and no
  /// `results` key) for bad input, so anything without results is "no match".
  static NpiLookupResult parseResponse(dynamic data) {
    // Total by contract: a maintenance page, a truncated body or a null all
    // mean the same thing to the caller — no match.
    dynamic j = data;
    if (j is String) {
      try {
        j = jsonDecode(j);
      } catch (_) {
        return const NpiLookupResult.none();
      }
    }
    if (j is! Map) return const NpiLookupResult.none();
    final results = j['results'];
    if (results is! List || results.isEmpty) return const NpiLookupResult.none();
    if (results.length > 1) return const NpiLookupResult.ambiguous();
    final first = results.first;
    if (first is! Map) return const NpiLookupResult.none();
    return NpiLookupResult.matched(NpiMatch.fromResult(first.cast<String, dynamic>()));
  }
}
