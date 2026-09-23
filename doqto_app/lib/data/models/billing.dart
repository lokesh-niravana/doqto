/// What the backend says about this doctor's subscription.
///
/// Prices come down with the status so the yearly saving is computed from what
/// Stripe actually charges. Typing the discount into the UI is how a price
/// change silently turns the copy into a lie.
class Billing {
  final bool entitled;

  /// `staff`, `trial`, `subscribed`, `grace` or `expired`.
  final String reason;
  final DateTime? trialEndsAt;
  final String? plan;
  final String? status;
  final DateTime? currentPeriodEnd;
  final int monthlyCents;
  final int yearlyCents;

  const Billing({
    required this.entitled,
    required this.reason,
    required this.monthlyCents,
    required this.yearlyCents,
    this.trialEndsAt,
    this.plan,
    this.status,
    this.currentPeriodEnd,
  });

  factory Billing.fromJson(Map<String, dynamic> j) => Billing(
        entitled: j['entitled'] as bool,
        reason: (j['reason'] ?? 'expired') as String,
        trialEndsAt: DateTime.tryParse((j['trial_ends_at'] ?? '') as String)?.toUtc(),
        plan: j['plan'] as String?,
        status: j['status'] as String?,
        currentPeriodEnd:
            DateTime.tryParse((j['current_period_end'] ?? '') as String)?.toUtc(),
        monthlyCents: (j['monthly_cents'] ?? 0) as int,
        yearlyCents: (j['yearly_cents'] ?? 0) as int,
      );

  /// Whole days remaining, rounded up: a trial with five hours left still has
  /// "1 day", never "0 days" while it works.
  int get trialDaysLeft {
    final end = trialEndsAt;
    if (end == null) return 0;
    final left = end.difference(DateTime.now().toUtc());
    return left.isNegative ? 0 : (left.inMinutes / (60 * 24)).ceil();
  }

  /// Percent saved by paying yearly, against twelve monthly payments.
  int get yearlySavingPercent {
    final year = monthlyCents * 12;
    if (year <= 0 || yearlyCents <= 0) return 0;
    return ((year - yearlyCents) / year * 100).round();
  }

  String get monthlyLabel => '\$${(monthlyCents / 100).toStringAsFixed(2)}/mo';
  String get yearlyLabel => '\$${(yearlyCents / 100).toStringAsFixed(0)}/yr';

  /// "$6.67/mo" — the yearly price spread over twelve months.
  String get yearlyPerMonthLabel =>
      '\$${(yearlyCents / 12 / 100).toStringAsFixed(2)}/mo';
}
