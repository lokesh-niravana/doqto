import 'message.dart';

/// What the per-chat gallery lists (`GET /conversations/{id}/media?type=`).
enum MediaKind {
  image('image'),
  video('video'),
  file('file'),
  link('link');

  final String wire;
  const MediaKind(this.wire);
}

/// One gallery row: the message plus the presigned URLs the server already
/// resolved (media object, or every http(s) link in a text message).
class MediaGalleryItem {
  final Message message;
  final List<String> urls;

  const MediaGalleryItem({required this.message, required this.urls});

  factory MediaGalleryItem.fromJson(Map<String, dynamic> j) => MediaGalleryItem(
        message: Message.fromJson((j['message'] as Map).cast<String, dynamic>()),
        urls: [for (final u in (j['urls'] as List? ?? const [])) u.toString()],
      );
}

/// One presigned part of a multipart upload.
class UploadPartUrl {
  final int partNumber;
  final String url;
  const UploadPartUrl({required this.partNumber, required this.url});
}

/// `POST /messages/upload-intent/{conv}`: where to PUT the bytes. Exactly one
/// of [putUrl] (single object) or [uploadId] + [partUrls] (multipart) is set;
/// [message] is set instead when the `client_id` was already completed.
class UploadIntent {
  final String intentId;
  final String key;
  final int partSize;
  final int expiresIn;
  final String? putUrl;
  final String? uploadId;
  final List<UploadPartUrl> partUrls;
  final String? thumbPutUrl;
  final Message? message;

  const UploadIntent({
    required this.intentId,
    required this.key,
    required this.partSize,
    required this.expiresIn,
    this.putUrl,
    this.uploadId,
    this.partUrls = const [],
    this.thumbPutUrl,
    this.message,
  });

  bool get isMultipart => uploadId != null && partUrls.isNotEmpty;

  factory UploadIntent.fromJson(Map<String, dynamic> j) => UploadIntent(
        intentId: j['intent_id'] as String,
        key: (j['key'] ?? '') as String,
        partSize: (j['part_size'] as num?)?.toInt() ?? 0,
        expiresIn: (j['expires_in'] as num?)?.toInt() ?? 0,
        putUrl: j['put_url'] as String?,
        uploadId: j['upload_id'] as String?,
        partUrls: [
          for (final p in (j['part_urls'] as List? ?? const []))
            UploadPartUrl(
              partNumber: ((p as Map)['part_number'] as num).toInt(),
              url: p['url'] as String,
            ),
        ],
        thumbPutUrl: j['thumb_put_url'] as String?,
        message: j['message'] is Map
            ? Message.fromJson((j['message'] as Map).cast<String, dynamic>())
            : null,
      );
}

/// Limits mirrored from the backend (docs/media.md).
class MediaLimits {
  MediaLimits._();

  static const int fileMaxBytes = 100 * 1024 * 1024;
  static const int videoMaxBytes = 100 * 1024 * 1024;

  /// Above this the legacy inline multipart route is not used; the presigned
  /// flow takes over (the server reads inline bodies into memory).
  static const int inlineMaxBytes = 8 * 1024 * 1024;
  static const int partSizeBytes = 8 * 1024 * 1024;
  static const int thumbMaxBytes = 300 * 1024;
  static const Duration videoMaxDuration = Duration(minutes: 10);
  static const voiceMinDuration = Duration(seconds: 1);
  static const voiceMaxDuration = Duration(minutes: 5);
  static const int multiPhotoMax = 30;
  static const int waveformBytes = 64;
}
