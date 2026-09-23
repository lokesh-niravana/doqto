import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/data/models/billing.dart';

void main() {
  Map<String, dynamic> json({
    bool entitled = true,
    String reason = 'trial',
    String? trialEndsAt,
    int monthly = 899,
    int yearly = 8000,
  }) => {
        'entitled': entitled,
        'reason': reason,
        'trial_ends_at': trialEndsAt,
        'plan': null,
        'status': null,
        'current_period_end': null,
        'monthly_cents': monthly,
        'yearly_cents': yearly,
      };

  test('reads the server payload', () {
    final b = Billing.fromJson(json(trialEndsAt: '2026-10-07T12:00:00Z'));

    expect(b.entitled, isTrue);
    expect(b.reason, 'trial');
    expect(b.trialEndsAt, DateTime.utc(2026, 10, 7, 12));
  });

  test('computes the yearly saving from the prices, not from copy', () {
    // 12 x $8.99 = $107.88 against $80 is 25.8%, which reads as 26%.
    expect(Billing.fromJson(json()).yearlySavingPercent, 26);
  });

  test('a cheaper monthly price moves the saving', () {
    expect(
      Billing.fromJson(json(monthly: 1000, yearly: 6000)).yearlySavingPercent,
      50,
    );
  });

  test('days left rounds up, so the last day still reads as one', () {
    final b = Billing.fromJson(json(
      trialEndsAt: DateTime.now().toUtc().add(const Duration(hours: 5)).toIso8601String(),
    ));

    expect(b.trialDaysLeft, 1);
  });

  test('an expired trial has no days left', () {
    final b = Billing.fromJson(json(
      entitled: false,
      reason: 'expired',
      trialEndsAt: DateTime.now().toUtc().subtract(const Duration(days: 1)).toIso8601String(),
    ));

    expect(b.trialDaysLeft, 0);
  });
}
