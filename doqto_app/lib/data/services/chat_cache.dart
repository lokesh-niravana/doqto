import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/conversation.dart';
import '../models/message.dart';

/// Read-through cache so a cold start with no network still shows history.
/// Write-through on every successful fetch; latest page only.
class ChatCache {
  static const boxName = 'chat_cache';
  Box<dynamic> get _box => Hive.box(boxName);

  static const _convsKey = 'conversations';
  String _msgsKey(String convId) => 'messages:$convId';

  Future<void> putConversations(List<Conversation> list) =>
      _box.put(_convsKey, jsonEncode([for (final c in list) c.toJson()]));

  List<Conversation>? conversations() => _decodeList(_convsKey, Conversation.fromJson);

  Future<void> putMessages(String convId, List<Message> msgs) =>
      _box.put(_msgsKey(convId), jsonEncode([for (final m in msgs) m.toJson()]));

  List<Message>? messages(String convId) => _decodeList(_msgsKey(convId), Message.fromJson);

  List<T>? _decodeList<T>(String key, T Function(Map<String, dynamic>) fromJson) {
    final raw = _box.get(key) as String?;
    if (raw == null) return null;
    try {
      return [
        for (final e in jsonDecode(raw) as List) fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return null; // schema drift: treat as cache miss
    }
  }

  // Emoji picker memory (wiped with the session like everything here).
  static const _recentEmojiKey = 'emoji_recent';
  static const _skinToneKey = 'emoji_skin_tone';
  static const recentEmojiMax = 16;

  List<String> recentEmoji() {
    final raw = _box.get(_recentEmojiKey);
    return raw is List ? [for (final e in raw) if (e is String) e] : const [];
  }

  Future<void> pushRecentEmoji(String emoji) {
    final next = [emoji, ...recentEmoji().where((e) => e != emoji)];
    return _box.put(_recentEmojiKey, next.take(recentEmojiMax).toList());
  }

  /// Index into an emoji's 5 tone variants, or null for the default yellow.
  int? skinTone() {
    final v = _box.get(_skinToneKey);
    return v is int && v >= 0 && v < 5 ? v : null;
  }

  Future<void> setSkinTone(int? tone) =>
      tone == null ? _box.delete(_skinToneKey) : _box.put(_skinToneKey, tone);

  Future<void> clear() => _box.clear();
}
