import '../../core/constants/api_routes.dart';
import '../api/api_client.dart';
import '../models/billing.dart';

class BillingRepository {
  final ApiClient _api;
  BillingRepository(this._api);

  Future<Billing> status() async =>
      Billing.fromJson(await _api.get(ApiRoutes.billing));

  /// A Stripe Checkout URL. Opens in the browser, never in a web view.
  Future<String> checkoutUrl(String plan) async {
    final res =
        await _api.post(ApiRoutes.billingCheckout, body: {'plan': plan});
    return res['url'] as String;
  }

  /// A StoreKit 2 transaction (its JWS). The server verifies Apple's
  /// signature and answers with the new billing status.
  Future<Billing> appleTransaction(String jws) async => Billing.fromJson(
      await _api.post(ApiRoutes.billingApple, body: {'transaction': jws}));

  /// Stripe's hosted portal: cancel, switch plan, change card.
  Future<String> portalUrl() async {
    final res = await _api.post(ApiRoutes.billingPortal);
    return res['url'] as String;
  }
}
