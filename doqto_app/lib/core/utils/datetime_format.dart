import 'package:intl/intl.dart';

/// WhatsApp-style compact timestamp for chat list rows.
/// - Today → "2:32 PM" (locale-aware; 24h where the locale uses it)
/// - Yesterday → "Yesterday"
/// - Within the past 7 days → weekday abbreviation ("Mon")
/// - Older → "dd/MM/yy"
String formatChatListTime(DateTime? dt) {
  if (dt == null) return '';
  final now = DateTime.now();
  final local = dt.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(that).inDays;
  if (diffDays == 0) return DateFormat.jm().format(local);
  if (diffDays == 1) return 'Yesterday';
  if (diffDays < 7) return DateFormat.E().format(local); // Mon, Tue…
  return DateFormat('dd/MM/yy').format(local);
}

/// Chat header line for a direct peer who is not online right now.
/// - Today → "last seen today at 2:02 PM"
/// - Yesterday → "last seen yesterday at 2:02 PM"
/// - Within the past 7 days → "last seen Mon at 2:02 PM"
/// - Older → "last seen 12/03/26"
/// Empty when nothing is known (hidden by their settings, or never online).
String formatLastSeen(DateTime? dt, {DateTime? now}) {
  if (dt == null) return '';
  final local = dt.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  final today = DateTime(ref.year, ref.month, ref.day);
  final that = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(that).inDays;
  final time = DateFormat.jm().format(local);
  if (diffDays <= 0) return 'last seen today at $time';
  if (diffDays == 1) return 'last seen yesterday at $time';
  if (diffDays < 7) return 'last seen ${DateFormat.E().format(local)} at $time';
  return 'last seen ${DateFormat('dd/MM/yy').format(local)}';
}
