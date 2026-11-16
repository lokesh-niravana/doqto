"""Server-side link previews (batch 4) with an SSRF guard.

The client never touches the third-party host: the server fetches the page,
extracts Open Graph / <title> / meta description, fetches the og:image and
inlines it as a small base64 data URL, and caches the result in Redis for
LINK_PREVIEW_CACHE_TTL_SEC.

Guard rails (every hop, redirects included):
  * http(s) only, no credentials in the URL, no non-standard ports
  * the host must resolve ONLY to public unicast addresses (no loopback,
    private, link-local, multicast, reserved, or IPv4-mapped tricks)
  * LINK_PREVIEW_TIMEOUT_SEC total, LINK_PREVIEW_MAX_BYTES body cap (streamed),
    at most LINK_PREVIEW_MAX_REDIRECTS redirects
Residual: DNS re-resolution between our check and httpx's connect (TOCTOU);
accepted for a preview fetcher that never carries credentials and whose
response is a title + a 50 KB image, never relayed verbatim.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import html
import ipaddress
import json
import re
import socket
from dataclasses import dataclass
from urllib.parse import urljoin, urlsplit

import httpx

from app.core.constants import (
    LINK_PREVIEW_CACHE_TTL_SEC,
    LINK_PREVIEW_IMAGE_MAX_BYTES,
    LINK_PREVIEW_MAX_BYTES,
    LINK_PREVIEW_MAX_REDIRECTS,
    LINK_PREVIEW_TEXT_MAX_LEN,
    LINK_PREVIEW_TIMEOUT_SEC,
)
from app.core.redis_keys import link_preview_key
from app.db.redis import get_redis
from app.schemas.message import LinkPreviewOut

_USER_AGENT = "DoqtoLinkPreview/1.0 (+https://doqto.ai)"
_ALLOWED_PORTS = {None, 80, 443}


class LinkPreviewError(Exception):
    """code: invalid_url | url_not_allowed | fetch_failed | not_html | too_large"""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


# --------------------------------------------------------------------------- #
# SSRF guard (pure, unit-tested)
# --------------------------------------------------------------------------- #
def is_public_ip(value: str) -> bool:
    """True only for globally routable unicast addresses."""
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return not (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
        or (isinstance(ip, ipaddress.IPv6Address) and ip.is_site_local)
        or not ip.is_global
    )


def validate_url(url: str) -> str:
    """Normalised URL or LinkPreviewError('invalid_url' | 'url_not_allowed')."""
    if not url or len(url) > 2048:
        raise LinkPreviewError("invalid_url")
    try:
        parts = urlsplit(url.strip())
    except ValueError as e:
        raise LinkPreviewError("invalid_url") from e
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise LinkPreviewError("invalid_url")
    if parts.username or parts.password:
        raise LinkPreviewError("url_not_allowed")
    try:
        port = parts.port
    except ValueError as e:
        raise LinkPreviewError("invalid_url") from e
    if port not in _ALLOWED_PORTS:
        raise LinkPreviewError("url_not_allowed")
    host = parts.hostname
    # A literal IP in the URL is checked right here; names are resolved later.
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if host in ("localhost",) or host.endswith((".localhost", ".local", ".internal")):
            raise LinkPreviewError("url_not_allowed") from None
    else:
        if not is_public_ip(host):
            raise LinkPreviewError("url_not_allowed")
    return parts.geturl()


async def _resolve_is_public(host: str) -> bool:
    try:
        ipaddress.ip_address(host)
        return is_public_ip(host)
    except ValueError:
        pass
    loop = asyncio.get_running_loop()
    try:
        infos = await loop.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    except (socket.gaierror, UnicodeError):
        return False
    addrs = {info[4][0] for info in infos}
    return bool(addrs) and all(is_public_ip(a) for a in addrs)


# --------------------------------------------------------------------------- #
# Fetcher (test seam: tests swap `fetcher` for a fake)
# --------------------------------------------------------------------------- #
@dataclass
class Fetched:
    url: str  # final URL
    content_type: str
    body: bytes


class HttpFetcher:
    async def fetch(self, url: str, *, max_bytes: int) -> Fetched:
        """GET with manual redirects (each hop re-validated) and a streamed
        body cap. Raises LinkPreviewError."""
        current = validate_url(url)
        timeout = httpx.Timeout(LINK_PREVIEW_TIMEOUT_SEC)
        async with httpx.AsyncClient(
            timeout=timeout, follow_redirects=False, headers={"User-Agent": _USER_AGENT}
        ) as client:
            for _ in range(LINK_PREVIEW_MAX_REDIRECTS + 1):
                host = urlsplit(current).hostname or ""
                if not await _resolve_is_public(host):
                    raise LinkPreviewError("url_not_allowed")
                try:
                    async with client.stream("GET", current) as resp:
                        if resp.is_redirect:
                            location = resp.headers.get("location")
                            if not location:
                                raise LinkPreviewError("fetch_failed")
                            current = validate_url(urljoin(current, location))
                            continue
                        if resp.status_code >= 400:
                            raise LinkPreviewError("fetch_failed")
                        declared = int(resp.headers.get("content-length") or 0)
                        if declared > max_bytes:
                            raise LinkPreviewError("too_large")
                        chunks: list[bytes] = []
                        size = 0
                        async for chunk in resp.aiter_bytes():
                            size += len(chunk)
                            if size > max_bytes:
                                raise LinkPreviewError("too_large")
                            chunks.append(chunk)
                        return Fetched(
                            url=str(resp.url),
                            content_type=resp.headers.get("content-type", ""),
                            body=b"".join(chunks),
                        )
                except httpx.HTTPError as e:
                    raise LinkPreviewError("fetch_failed") from e
        raise LinkPreviewError("fetch_failed")


fetcher = HttpFetcher()


# --------------------------------------------------------------------------- #
# HTML extraction (pure, unit-tested)
# --------------------------------------------------------------------------- #
_META_RE = re.compile(r"<meta\s+[^>]*>", re.IGNORECASE)
_ATTR_RE = re.compile(r"""([a-zA-Z:-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))""")
_TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)


def _clean(text: str | None) -> str | None:
    if not text:
        return None
    text = html.unescape(re.sub(r"\s+", " ", text)).strip()
    if not text:
        return None
    if len(text) > LINK_PREVIEW_TEXT_MAX_LEN:
        text = text[: LINK_PREVIEW_TEXT_MAX_LEN - 1].rstrip() + "…"
    return text


def extract_metadata(body: str, base_url: str) -> dict[str, str | None]:
    """og:* first, then <title> / meta description. Image URL is absolutised."""
    meta: dict[str, str] = {}
    for tag in _META_RE.findall(body):
        attrs: dict[str, str] = {}
        for m in _ATTR_RE.finditer(tag):
            attrs[m.group(1).lower()] = m.group(3) or m.group(4) or m.group(5) or ""
        key = (attrs.get("property") or attrs.get("name") or "").lower()
        content = attrs.get("content")
        if key and content and key not in meta:
            meta[key] = content
    title_m = _TITLE_RE.search(body)
    image = meta.get("og:image") or meta.get("twitter:image")
    return {
        "title": _clean(meta.get("og:title") or (title_m.group(1) if title_m else None)),
        "description": _clean(
            meta.get("og:description") or meta.get("description") or meta.get("twitter:description")
        ),
        "site_name": _clean(meta.get("og:site_name")),
        "image_url": urljoin(base_url, image) if image else None,
    }


def _decode(body: bytes) -> str:
    for enc in ("utf-8", "latin-1"):
        try:
            return body.decode(enc)
        except UnicodeDecodeError:
            continue
    return body.decode("utf-8", errors="replace")


# --------------------------------------------------------------------------- #
# Service
# --------------------------------------------------------------------------- #
class LinkPreviewService:
    @staticmethod
    async def preview(url: str) -> LinkPreviewOut:
        """Cached preview for `url`. Raises LinkPreviewError."""
        normalised = validate_url(url)
        redis = await get_redis()
        key = link_preview_key(hashlib.sha256(normalised.encode()).hexdigest())
        cached = await redis.get(key)
        if cached:
            return LinkPreviewOut.model_validate(json.loads(cached))
        out = await LinkPreviewService._build(normalised)
        await redis.set(key, out.model_dump_json(), ex=LINK_PREVIEW_CACHE_TTL_SEC)
        return out

    @staticmethod
    async def _build(url: str) -> LinkPreviewOut:
        page = await fetcher.fetch(url, max_bytes=LINK_PREVIEW_MAX_BYTES)
        if "html" not in page.content_type.lower():
            raise LinkPreviewError("not_html")
        meta = extract_metadata(_decode(page.body), page.url)
        image_data_url = None
        if meta["image_url"]:
            try:
                img = await fetcher.fetch(
                    meta["image_url"], max_bytes=LINK_PREVIEW_IMAGE_MAX_BYTES
                )
                ctype = img.content_type.split(";")[0].strip().lower()
                if ctype.startswith("image/") and img.body:
                    image_data_url = (
                        f"data:{ctype};base64,{base64.b64encode(img.body).decode()}"
                    )
            except LinkPreviewError:
                image_data_url = None  # a preview without an image is still a preview
        return LinkPreviewOut(
            url=page.url,
            title=meta["title"],
            description=meta["description"],
            site_name=meta["site_name"],
            image_data_url=image_data_url,
        )
