import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../core/constants/strings.dart';
import '../core/di/providers.dart';
import '../core/utils/error_messages.dart';
import '../data/api/api_client.dart';
import 'auth_state.dart';
import 'billing_state.dart';

/// Whether the app sells through In-App Purchase. iOS only: Apple requires it
/// there (3.1.1); the Stripe link-out stays beside it as the second option.
final appleIapProvider = Provider<bool>((ref) => Platform.isIOS);

const appleProductIds = {
  'monthly': 'com.doqto.ios.monthly',
  'yearly': 'com.doqto.ios.yearly',
};

/// StoreKit 2 purchases. Every transaction the store delivers — a purchase,
/// a renewal while the app was closed, a restore — goes to the backend, which
/// verifies Apple's signature and decides access. The app never unlocks
/// anything on its own say-so.
class AppleIap {
  final Ref _ref;
  AppleIap(this._ref);

  StreamSubscription<List<PurchaseDetails>>? _sub;
  // The buy or restore the screen is waiting on. Completes with an error
  // message, or null on success.
  Completer<String?>? _waiting;

  void start() {
    _sub ??= InAppPurchase.instance.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) => _finish(ErrorMessages.forApi(e)),
    );
  }

  void dispose() => _sub?.cancel();

  /// Apple's own localized price per plan, e.g. {'yearly': '$79.99'}. Empty
  /// when the store can't be reached; the screen falls back to our prices.
  Future<Map<String, ProductDetails>> products() async {
    final res = await InAppPurchase.instance
        .queryProductDetails(appleProductIds.values.toSet());
    return {
      for (final e in appleProductIds.entries)
        for (final p in res.productDetails)
          if (p.id == e.value) e.key: p,
    };
  }

  Future<String?> buy(ProductDetails product) async {
    final userId = _ref.read(authProvider).user?.id;
    _waiting = Completer<String?>();
    try {
      // The account token ties the subscription to this doctor on Apple's
      // side too, so the server can match renewals and refuse a shared
      // Apple ID.
      await InAppPurchase.instance.buyNonConsumable(
        purchaseParam:
            PurchaseParam(productDetails: product, applicationUserName: userId),
      );
    } catch (e) {
      _finish(ErrorMessages.forApi(e));
    }
    return _waiting!.future;
  }

  Future<String?> restore() async {
    _waiting = Completer<String?>();
    await InAppPurchase.instance.restorePurchases();
    // Nothing to restore delivers no event at all.
    return _waiting!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => Strings.iapNothingToRestore,
    );
  }

  void _finish(String? error) {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete(error);
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    String? error;
    var verified = false;
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.pending:
          continue; // Ask to Buy and the like: wait for the next event.
        case PurchaseStatus.canceled:
          error = Strings.iapCancelled;
        case PurchaseStatus.error:
          error = p.error?.message ?? Strings.iapFailed;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          try {
            await _ref
                .read(billingRepositoryProvider)
                .appleTransaction(p.verificationData.serverVerificationData);
            verified = true;
          } on ApiException catch (e) {
            if (e.status == null || e.status! >= 500) {
              // Server unreachable: leave the transaction unfinished and
              // StoreKit hands it back on the next launch.
              error = ErrorMessages.forApi(e);
              continue;
            }
            error = e.detail == 'apple_subscription_in_use'
                ? Strings.iapInUse
                : ErrorMessages.forApi(e);
          } catch (e) {
            error = ErrorMessages.forApi(e);
            continue;
          }
      }
      if (p.pendingCompletePurchase) {
        await InAppPurchase.instance.completePurchase(p);
      }
    }
    if (verified) {
      await _ref.read(billingProvider.notifier).refresh();
      await _ref.read(authProvider.notifier).recheckSubscription();
    }
    _finish(verified ? null : error);
  }
}

final appleIapServiceProvider = Provider<AppleIap>((ref) {
  final iap = AppleIap(ref);
  ref.onDispose(iap.dispose);
  return iap;
});

/// Watched by the app root so renewals and interrupted purchases are picked up
/// from launch, not only while the plan screen is open.
final appleIapListenerProvider = Provider<void>((ref) {
  if (ref.watch(appleIapProvider)) ref.watch(appleIapServiceProvider).start();
});
