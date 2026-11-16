import 'package:flutter/services.dart';

/// One PDF page's size in points, used to lay out before it is rendered.
class PdfPageSize {
  final double width;
  final double height;
  const PdfPageSize(this.width, this.height);
}

/// The phone's own document tools. No third-party viewer: nothing leaves the
/// device, and no plugin can reintroduce the embedded framework behind the
/// ITMS-90111 rejections.
abstract class DocumentViewer {
  /// iOS: full-screen QuickLook inside the app. False when it cannot render
  /// this file type.
  Future<bool> preview(String path);

  /// Android: hand the file to an installed app. False when none can open it.
  Future<bool> openExternally(String path, String mimeType);

  /// Android: page sizes of a PDF, for an in-app viewer.
  Future<List<PdfPageSize>> pdfOpen(String path);

  /// Android: one page as PNG, [width] pixels wide.
  Future<Uint8List> pdfPage(int index, int width);

  Future<void> pdfClose();
}

class NativeDocumentViewer implements DocumentViewer {
  const NativeDocumentViewer();

  static const _channel = MethodChannel('doqto/documents');

  @override
  Future<bool> preview(String path) async =>
      await _channel.invokeMethod<bool>('preview', {'path': path}) ?? false;

  @override
  Future<bool> openExternally(String path, String mimeType) async =>
      await _channel.invokeMethod<bool>('openExternal', {
        'path': path,
        'mime': mimeType,
      }) ??
      false;

  @override
  Future<List<PdfPageSize>> pdfOpen(String path) async {
    final raw = await _channel.invokeListMethod<dynamic>('pdfOpen', {
      'path': path,
    });
    return [
      for (final p in raw ?? const [])
        PdfPageSize(
          ((p as Map)['w'] as num).toDouble(),
          (p['h'] as num).toDouble(),
        ),
    ];
  }

  @override
  Future<Uint8List> pdfPage(int index, int width) async => (await _channel
      .invokeMethod<Uint8List>('pdfPage', {'index': index, 'width': width}))!;

  @override
  Future<void> pdfClose() => _channel.invokeMethod<void>('pdfClose');
}
