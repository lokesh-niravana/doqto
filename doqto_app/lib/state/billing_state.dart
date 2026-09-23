import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../data/models/billing.dart';

/// The app's cached view of the subscription. Null means "not asked yet, or
/// the server could not be reached" — never "expired". Only the server
/// decides that.
class BillingNotifier extends AsyncNotifier<Billing?> {
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
    final value = await _fetch();
    state = AsyncValue.data(value);
    return value;
  }

  /// Stripe's webhook can land a few seconds after the browser sends the
  /// doctor back. Poll briefly rather than show them a stale paywall.
  Future<Billing?> pollAfterCheckout() async {
    for (var i = 0; i < 10; i++) {
      final value = await refresh();
      if (value?.entitled == true) return value;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return state.value;
  }
}

final billingProvider =
    AsyncNotifierProvider<BillingNotifier, Billing?>(BillingNotifier.new);
