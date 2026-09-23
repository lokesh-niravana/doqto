import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../data/models/billing.dart';

/// The app's cached view of the subscription. Null means "not asked yet, or
/// the server could not be reached" — never "expired". Only the server
/// decides that.
class BillingNotifier extends AsyncNotifier<Billing?> {
  // Bumped by [reset]. A fetch that started before sign-out must not write the
  // previous doctor's billing back, and a poll must stop.
  int _generation = 0;

  @override
  Future<Billing?> build() => _fetch();

  Future<Billing?> _fetch() async {
    try {
      return await ref.read(billingRepositoryProvider).status();
    } catch (_) {
      return null;
    }
  }

  Future<Billing?> refresh() async {
    final generation = _generation;
    final value = await _fetch();
    if (generation != _generation) return null;
    state = AsyncValue.data(value);
    return value;
  }

  /// On sign-out. A plain invalidate would keep the old value visible while
  /// the refetch loads, so drop it first; the next watcher fetches afresh.
  void reset() {
    _generation++;
    state = const AsyncValue.data(null);
    ref.invalidateSelf();
  }

  /// Stripe's webhook can land a few seconds after the browser sends the
  /// doctor back. Poll briefly rather than show them a stale paywall.
  Future<Billing?> pollAfterCheckout() async {
    final generation = _generation;
    for (var i = 0; i < 10; i++) {
      if (generation != _generation) return null;
      final value = await refresh();
      if (value?.entitled == true) return value;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return generation == _generation ? state.value : null;
  }
}

final billingProvider =
    AsyncNotifierProvider<BillingNotifier, Billing?>(BillingNotifier.new);
