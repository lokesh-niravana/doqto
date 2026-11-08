import 'dart:typed_data';

/// Strip metadata (EXIF, XMP, IPTC, comments) from a photo before it leaves
/// the phone (batch 5). GPS coordinates, camera serials and capture times are
/// PHI-adjacent and never belong in a chat upload. Lossless: JPEG and PNG are
/// rewritten segment by segment with the pixel data untouched; anything else
/// is returned as-is (the server re-encodes those through Pillow).
///
/// The server strips too (`image_service.py`); this is defence in depth.
class ImageMetadata {
  ImageMetadata._();

  static const _jpegSoi = [0xFF, 0xD8];
  static final _pngSig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  /// Returns the image without metadata segments. Unchanged input when the
  /// format is unknown or the file is malformed (never throws).
  static Uint8List strip(Uint8List bytes) {
    try {
      if (_isJpeg(bytes)) return _stripJpeg(bytes);
      if (_isPng(bytes)) return _stripPng(bytes);
    } catch (_) {
      // Malformed: better to send the original than to send nothing.
    }
    return bytes;
  }

  static bool _isJpeg(Uint8List b) =>
      b.length > 4 && b[0] == _jpegSoi[0] && b[1] == _jpegSoi[1];

  static bool _isPng(Uint8List b) {
    if (b.length < _pngSig.length) return false;
    for (var i = 0; i < _pngSig.length; i++) {
      if (b[i] != _pngSig[i]) return false;
    }
    return true;
  }

  /// JPEG markers that carry metadata. APP0 (JFIF), APP2 (ICC colour profile)
  /// and APP14 (Adobe colour transform) stay — they describe pixels, not the
  /// photographer.
  static bool _isMetadataMarker(int marker) {
    switch (marker) {
      case 0xE1: // APP1: Exif (GPS, camera, timestamps) and XMP
      case 0xE3: // APP3: Kodak / Exif extension
      case 0xE4: // APP4
      case 0xE5: // APP5
      case 0xE6: // APP6
      case 0xE7: // APP7
      case 0xE8: // APP8
      case 0xE9: // APP9
      case 0xEA: // APP10
      case 0xEB: // APP11
      case 0xEC: // APP12: picture info / Ducky
      case 0xED: // APP13: Photoshop IRB / IPTC
      case 0xEF: // APP15
      case 0xFE: // COM: comment
        return true;
      default:
        return false;
    }
  }

  static Uint8List _stripJpeg(Uint8List b) {
    final out = BytesBuilder(copy: false);
    out.add(_jpegSoi);
    var i = 2;
    while (i + 4 <= b.length) {
      if (b[i] != 0xFF) return b; // not where a marker should be: give up
      final marker = b[i + 1];
      if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 || marker == 0xFF) {
        // Standalone markers (no length).
        out.add([0xFF, marker]);
        i += 2;
        continue;
      }
      if (marker == 0xD9) {
        // EOI: done (ignore any trailer, which is where some apps hide data).
        out.add([0xFF, 0xD9]);
        return out.toBytes();
      }
      final len = (b[i + 2] << 8) | b[i + 3];
      if (len < 2 || i + 2 + len > b.length) return b;
      if (marker == 0xDA) {
        // SOS: header, then entropy-coded data up to EOI — copy the rest.
        out.add(Uint8List.sublistView(b, i, b.length));
        return out.toBytes();
      }
      if (!_isMetadataMarker(marker)) {
        out.add(Uint8List.sublistView(b, i, i + 2 + len));
      }
      i += 2 + len;
    }
    return b;
  }

  static const _pngDrop = {'tEXt', 'zTXt', 'iTXt', 'eXIf', 'tIME'};

  static Uint8List _stripPng(Uint8List b) {
    final out = BytesBuilder(copy: false);
    out.add(_pngSig);
    var i = _pngSig.length;
    final data = ByteData.sublistView(b);
    while (i + 12 <= b.length) {
      final len = data.getUint32(i);
      final type = String.fromCharCodes(b, i + 4, i + 8);
      final end = i + 12 + len;
      if (end > b.length) return b;
      if (!_pngDrop.contains(type)) out.add(Uint8List.sublistView(b, i, end));
      i = end;
      if (type == 'IEND') break;
    }
    return out.toBytes();
  }

  /// True when a JPEG still carries an APP1 (Exif/XMP) segment — for tests
  /// and a last-line check before upload.
  static bool hasExif(Uint8List b) {
    if (!_isJpeg(b)) return false;
    var i = 2;
    while (i + 4 <= b.length && b[i] == 0xFF) {
      final marker = b[i + 1];
      if (marker == 0xDA || marker == 0xD9) return false;
      final len = (b[i + 2] << 8) | b[i + 3];
      if (marker == 0xE1) return true;
      i += 2 + len;
    }
    return false;
  }
}
