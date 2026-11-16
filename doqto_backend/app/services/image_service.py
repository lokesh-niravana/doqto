"""Server-side metadata stripping for uploaded images (batch 5).

The client strips EXIF before upload; this is defence in depth so a GPS fix
or a device serial never reaches S3 even from an old or buggy client.

JPEG and PNG are rewritten losslessly by walking their container structure
and dropping the metadata segments/chunks (no re-encode, pixels untouched).
Anything else Pillow can open (WebP, HEIF via plugin, …) is re-encoded
without metadata; a payload Pillow cannot open is returned unchanged.
"""

from __future__ import annotations

import io
import logging
import struct

log = logging.getLogger("doqto.images")

_JPEG_SOI = b"\xff\xd8"
# APP1 (Exif / XMP), APP13 (Photoshop IRB / IPTC) and COM carry the
# identifying metadata. APP0 (JFIF), APP2 (ICC colour profile) and APP14
# (Adobe colour transform) are needed to render the image faithfully.
_JPEG_DROP_MARKERS = {0xE1, 0xED, 0xFE}
_JPEG_STANDALONE = {0xD8, 0x01, *range(0xD0, 0xD8)}

_PNG_SIG = b"\x89PNG\r\n\x1a\n"
# eXIf, text chunks and the time chunk are metadata; everything else stays.
_PNG_DROP_CHUNKS = {b"eXIf", b"tEXt", b"iTXt", b"zTXt", b"tIME"}


def _strip_jpeg(data: bytes) -> bytes:
    out = bytearray(_JPEG_SOI)
    i = 2
    n = len(data)
    while i + 4 <= n:
        if data[i] != 0xFF:
            # Not at a marker: structure is off — keep the rest verbatim.
            out += data[i:]
            return bytes(out)
        marker = data[i + 1]
        if marker == 0xFF:  # fill byte
            i += 1
            continue
        if marker in _JPEG_STANDALONE:
            out += data[i : i + 2]
            i += 2
            continue
        if marker == 0xDA:  # SOS: entropy-coded data follows to EOI; copy the rest.
            out += data[i:]
            return bytes(out)
        (seg_len,) = struct.unpack(">H", data[i + 2 : i + 4])
        seg_end = i + 2 + seg_len
        if seg_end > n:
            out += data[i:]
            return bytes(out)
        if marker not in _JPEG_DROP_MARKERS:
            out += data[i:seg_end]
        i = seg_end
    out += data[i:]
    return bytes(out)


def _strip_png(data: bytes) -> bytes:
    out = bytearray(_PNG_SIG)
    i = len(_PNG_SIG)
    n = len(data)
    while i + 8 <= n:
        (length,) = struct.unpack(">I", data[i : i + 4])
        ctype = data[i + 4 : i + 8]
        end = i + 12 + length
        if end > n:
            out += data[i:]
            return bytes(out)
        if ctype not in _PNG_DROP_CHUNKS:
            out += data[i:end]
        i = end
    out += data[i:]
    return bytes(out)


def _strip_with_pillow(data: bytes) -> bytes | None:
    try:
        from PIL import Image
    except ImportError:  # pragma: no cover - Pillow is in requirements
        return None
    try:
        with Image.open(io.BytesIO(data)) as img:
            fmt = img.format
            if fmt is None:
                return None
            img.load()
            clean = img.copy()  # drops .info (exif / xmp / icc / comments)
            buf = io.BytesIO()
            save_kwargs: dict = {}
            if fmt in ("JPEG", "WEBP"):
                save_kwargs["quality"] = 92
            clean.save(buf, format=fmt, **save_kwargs)
            return buf.getvalue()
    except Exception as e:  # noqa: BLE001 — never fail an upload over this
        log.warning("exif strip via Pillow failed (%s); storing as received", e)
        return None


def strip_image_metadata(data: bytes, content_type: str | None) -> bytes:
    """Return `data` without EXIF / XMP / IPTC / text metadata. Lossless for
    JPEG and PNG; re-encoded for other formats Pillow knows; unchanged when the
    payload is not a recognisable image."""
    if data[:2] == _JPEG_SOI:
        return _strip_jpeg(data)
    if data[:8] == _PNG_SIG:
        return _strip_png(data)
    if content_type and content_type.startswith("image/"):
        stripped = _strip_with_pillow(data)
        if stripped is not None:
            return stripped
    return data


def has_exif(data: bytes) -> bool:
    """Test helper / sanity check: does a JPEG still carry an APP1 Exif segment,
    or a PNG an eXIf / text chunk?"""
    if data[:2] == _JPEG_SOI:
        i = 2
        while i + 4 <= len(data) and data[i] == 0xFF:
            marker = data[i + 1]
            if marker == 0xDA:
                return False
            if marker in _JPEG_STANDALONE:
                i += 2
                continue
            (seg_len,) = struct.unpack(">H", data[i + 2 : i + 4])
            if marker == 0xE1 and data[i + 4 : i + 10] == b"Exif\x00\x00":
                return True
            i += 2 + seg_len
        return False
    if data[:8] == _PNG_SIG:
        i = 8
        while i + 8 <= len(data):
            (length,) = struct.unpack(">I", data[i : i + 4])
            if data[i + 4 : i + 8] in _PNG_DROP_CHUNKS:
                return True
            i += 12 + length
        return False
    return False
