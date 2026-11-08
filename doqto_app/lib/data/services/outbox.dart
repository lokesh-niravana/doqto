import 'dart:io';
import 'dart:math';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// RFC-4122 v4 uuid from Random.secure — avoids a uuid package dependency.
String uuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}'
      '-${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}

/// What kind of send an outbox entry represents. Stored as a plain string in
/// Hive; legacy maps without a `kind` key decode as [text].
enum OutboxKind {
  text,
  media,
  voice;

  static OutboxKind fromName(String? s) => switch (s) {
        'media' => OutboxKind.media,
        'voice' => OutboxKind.voice,
        _ => OutboxKind.text,
      };
}

class OutboxEntry {
  final String clientId;
  final String conversationId;
  final OutboxKind kind;
  final String content;
  final DateTime createdAt;

  // Media/voice only — payload lives on disk (see [OutboxMediaStore]), never
  // in Hive, so a big attachment can't bloat the box.
  final String? filePath;
  final String? fileName;
  final String? mimeType;
  final int? durationSec;
  final String? transcript;

  // Text only: the message this one quotes (batch 4).
  final String? replyToId;

  const OutboxEntry({
    required this.clientId,
    required this.conversationId,
    this.kind = OutboxKind.text,
    this.content = '',
    required this.createdAt,
    this.filePath,
    this.fileName,
    this.mimeType,
    this.durationSec,
    this.transcript,
    this.replyToId,
  });

  Map<String, dynamic> toMap() => {
        'client_id': clientId,
        'conversation_id': conversationId,
        'kind': kind.name,
        'content': content,
        'created_at': createdAt.toIso8601String(),
        'file_path': filePath,
        'file_name': fileName,
        'mime_type': mimeType,
        'duration_sec': durationSec,
        'transcript': transcript,
        'reply_to_id': replyToId,
      };

  factory OutboxEntry.fromMap(Map<dynamic, dynamic> m) => OutboxEntry(
        clientId: m['client_id'] as String,
        conversationId: m['conversation_id'] as String,
        kind: OutboxKind.fromName(m['kind'] as String?),
        content: (m['content'] as String?) ?? '',
        createdAt: DateTime.parse(m['created_at'] as String),
        filePath: m['file_path'] as String?,
        fileName: m['file_name'] as String?,
        mimeType: m['mime_type'] as String?,
        durationSec: m['duration_sec'] as int?,
        transcript: m['transcript'] as String?,
        replyToId: m['reply_to_id'] as String?,
      );
}

/// Copies attachment payloads into app-owned storage before enqueueing, so
/// picker temp files (which the OS may evict) can't disappear before a retry
/// succeeds. Files are named `<clientId>.<ext>` under Documents/outbox_media.
// ponytail: outbox_media/ files are NOT encrypted at rest (deferred per the
// HIPAA remediation plan — the Hive boxes are; Android backup is disabled via
// android:allowBackup="false"). Revisit if attachment volume/sensitivity grows.
class OutboxMediaStore {
  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/outbox_media');
    await dir.create(recursive: true);
    return dir;
  }

  String _ext(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return (dot > 0 && dot < fileName.length - 1)
        ? fileName.substring(dot + 1)
        : 'bin';
  }

  /// Persist raw bytes; returns the durable path.
  Future<String> persistBytes({
    required String clientId,
    required String fileName,
    required List<int> bytes,
  }) async {
    final dir = await _dir();
    final path = '${dir.path}/$clientId.${_ext(fileName)}';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Persist an existing file (e.g. a voice recording); returns the durable path.
  Future<String> persistFile({
    required String clientId,
    required String sourcePath,
  }) async {
    final dir = await _dir();
    final path = '${dir.path}/$clientId.${_ext(sourcePath.split('/').last)}';
    await File(sourcePath).copy(path);
    return path;
  }

  /// H2: remove every persisted attachment (logout / session-end wipe).
  Future<void> deleteAll() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/outbox_media');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}

/// Durable queue of unsent messages (text, media, voice), keyed by clientId.
/// Survives app kill; drained on start / reconnect / manual retry.
class Outbox {
  static const boxName = 'outbox';
  Box<dynamic> get _box => Hive.box(boxName);

  Future<void> add(OutboxEntry e) => _box.put(e.clientId, e.toMap());

  /// Removes the entry AND its persisted media file (if any) — the single
  /// cleanup path for both successful delivery and discard.
  Future<void> remove(String clientId) async {
    final raw = _box.get(clientId);
    if (raw is Map) {
      final path = raw['file_path'] as String?;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {} // already gone — fine
      }
    }
    await _box.delete(clientId);
  }

  bool contains(String clientId) => _box.containsKey(clientId);

  /// H2: drop all queued entries. Media files are removed separately via
  /// [OutboxMediaStore.deleteAll].
  Future<void> clear() => _box.clear();

  /// Oldest-first, optionally scoped to one conversation.
  List<OutboxEntry> pending({String? conversationId}) {
    final list = _box.values
        .map((v) => OutboxEntry.fromMap(v as Map))
        .where((e) => conversationId == null || e.conversationId == conversationId)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }
}
