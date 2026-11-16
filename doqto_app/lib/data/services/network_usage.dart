import 'package:flutter/foundation.dart';

/// Bytes sent and received by the app (batch 5, Storage and data). Counted
/// by the API client's interceptor and by the direct S3 PUT / media
/// downloads; persisted through [NetworkUsageStore] so the numbers survive a
/// restart. Counts only — never what was transferred.
class NetworkUsage extends ChangeNotifier {
  NetworkUsage({NetworkUsageStore? store}) : _store = store {
    final saved = _store?.load();
    if (saved != null) {
      _sent = saved.$1;
      _received = saved.$2;
      _since = saved.$3;
    }
  }

  final NetworkUsageStore? _store;
  int _sent = 0;
  int _received = 0;
  DateTime? _since;

  int get bytesSent => _sent;
  int get bytesReceived => _received;

  /// When the counters were last reset (null = never, i.e. since install).
  DateTime? get since => _since;

  void addSent(int bytes) {
    if (bytes <= 0) return;
    _sent += bytes;
    _touch();
  }

  void addReceived(int bytes) {
    if (bytes <= 0) return;
    _received += bytes;
    _touch();
  }

  void reset() {
    _sent = 0;
    _received = 0;
    _since = DateTime.now().toUtc();
    _touch();
  }

  void _touch() {
    notifyListeners();
    _store?.save(_sent, _received, _since);
  }

  /// "1.2 MB" style label.
  static String format(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// Where the counters live between launches (the encrypted chat cache box in
/// production, memory in tests).
abstract class NetworkUsageStore {
  (int, int, DateTime?)? load();
  void save(int sent, int received, DateTime? since);
}
