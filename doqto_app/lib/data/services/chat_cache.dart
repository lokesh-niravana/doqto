import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/conversation.dart';
import '../models/media_settings.dart';
import '../models/message.dart';
import 'network_usage.dart';

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

  // --- Drafts (batch 3): unsent composer text per conversation. PHI, so it
  // lives in this encrypted box and is wiped with the session.
  static const _draftPrefix = 'draft:';

  String? draft(String convId) {
    final v = _box.get('$_draftPrefix$convId');
    return v is String && v.isNotEmpty ? v : null;
  }

  Future<void> putDraft(String convId, String? text) {
    final key = '$_draftPrefix$convId';
    if (text == null || text.trim().isEmpty) return _box.delete(key);
    return _box.put(key, text);
  }

  /// Every stored draft, keyed by conversation id (chat list previews).
  Map<String, String> drafts() {
    final out = <String, String>{};
    for (final k in _box.keys) {
      if (k is String && k.startsWith(_draftPrefix)) {
        final v = _box.get(k);
        if (v is String && v.isNotEmpty) out[k.substring(_draftPrefix.length)] = v;
      }
    }
    return out;
  }

  // "Keep chats archived" (batch 3): when off, a new message unarchives.
  static const _keepArchivedKey = 'keep_archived';

  bool keepArchived() {
    final v = _box.get(_keepArchivedKey);
    return v is bool ? v : true;
  }

  Future<void> setKeepArchived(bool value) => _box.put(_keepArchivedKey, value);

  // --- Storage and data (batch 5): upload quality + auto-download rules.
  static const _mediaSettingsKey = 'media_settings';

  MediaSettings mediaSettings() {
    final raw = _box.get(_mediaSettingsKey);
    if (raw is! String) return MediaSettings.defaults;
    try {
      return MediaSettings.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      return MediaSettings.defaults;
    }
  }

  Future<void> putMediaSettings(MediaSettings s) =>
      _box.put(_mediaSettingsKey, jsonEncode(s.toJson()));

  // --- Network usage counters (batch 5).
  static const _usageKey = 'network_usage';

  (int, int, DateTime?)? networkUsage() {
    final raw = _box.get(_usageKey);
    if (raw is! Map) return null;
    final since = raw['since'];
    return (
      (raw['sent'] as num?)?.toInt() ?? 0,
      (raw['received'] as num?)?.toInt() ?? 0,
      since is String ? DateTime.tryParse(since) : null,
    );
  }

  Future<void> putNetworkUsage(int sent, int received, DateTime? since) =>
      _box.put(_usageKey, {'sent': sent, 'received': received, 'since': since?.toIso8601String()});

  // --- Media index (batch 5, Manage storage): which chat a cached file
  // belongs to and how big it is, so storage can be shown and cleared per
  // chat. Key: `media_index:<messageId>`.
  static const _mediaIndexPrefix = 'media_index:';

  Future<void> putMediaIndex(String messageId, String conversationId, int bytes) =>
      _box.put('$_mediaIndexPrefix$messageId', {'c': conversationId, 'b': bytes});

  Future<void> removeMediaIndex(String messageId) => _box.delete('$_mediaIndexPrefix$messageId');

  /// Every indexed file: message id → (conversation id, bytes).
  Map<String, (String, int)> mediaIndex() {
    final out = <String, (String, int)>{};
    for (final k in _box.keys) {
      if (k is String && k.startsWith(_mediaIndexPrefix)) {
        final v = _box.get(k);
        if (v is Map) {
          out[k.substring(_mediaIndexPrefix.length)] =
              ((v['c'] ?? '').toString(), (v['b'] as num?)?.toInt() ?? 0);
        }
      }
    }
    return out;
  }

  Future<void> clearMediaIndex() async {
    for (final k in _box.keys.whereType<String>().where((k) => k.startsWith(_mediaIndexPrefix)).toList()) {
      await _box.delete(k);
    }
  }

  Future<void> clear() => _box.clear();
}

/// [NetworkUsageStore] over the encrypted chat cache box.
class ChatCacheUsageStore implements NetworkUsageStore {
  final ChatCache cache;
  ChatCacheUsageStore(this.cache);

  @override
  (int, int, DateTime?)? load() {
    try {
      return cache.networkUsage();
    } catch (_) {
      return null;
    }
  }

  @override
  void save(int sent, int received, DateTime? since) {
    try {
      cache.putNetworkUsage(sent, received, since);
    } catch (_) {}
  }
}
