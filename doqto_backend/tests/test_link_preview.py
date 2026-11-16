"""Link previews (batch 4): SSRF guard, metadata extraction, the route
(privacy flag, caching, error mapping) with a fake fetcher."""
from __future__ import annotations

import base64

import pytest
from sqlalchemy import select

from app.core.enums import AuditAction
from app.models import AuditLog, UserPrivacySettings
from app.services import link_preview_service as lps
from app.services.link_preview_service import (
    Fetched,
    LinkPreviewError,
    extract_metadata,
    is_public_ip,
    validate_url,
)
from tests import helpers

URL = "/api/v1/link-preview"


# --------------------------------------------------------------------------- #
# Guard (pure)
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    "ip",
    [
        "127.0.0.1", "10.0.0.1", "172.16.5.5", "192.168.1.1", "169.254.169.254",
        "0.0.0.0", "224.0.0.1", "::1", "fe80::1", "fc00::1", "::ffff:127.0.0.1",
        "::ffff:10.0.0.1", "100.64.0.1", "not-an-ip",
    ],
)
def test_private_and_special_addresses_are_rejected(ip):
    assert is_public_ip(ip) is False


@pytest.mark.parametrize("ip", ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"])
def test_public_addresses_are_accepted(ip):
    assert is_public_ip(ip) is True


@pytest.mark.parametrize(
    "url, code",
    [
        ("ftp://example.com/x", "invalid_url"),
        ("file:///etc/passwd", "invalid_url"),
        ("javascript:alert(1)", "invalid_url"),
        ("http://", "invalid_url"),
        ("not a url", "invalid_url"),
        ("http://user:pw@example.com/", "url_not_allowed"),
        ("http://example.com:8080/", "url_not_allowed"),
        ("http://127.0.0.1/", "url_not_allowed"),
        ("http://[::1]/", "url_not_allowed"),
        ("http://169.254.169.254/latest/meta-data", "url_not_allowed"),
        ("http://localhost/", "url_not_allowed"),
        ("http://db.internal/", "url_not_allowed"),
        ("http://printer.local/", "url_not_allowed"),
    ],
)
def test_validate_url_refuses(url, code):
    with pytest.raises(LinkPreviewError) as e:
        validate_url(url)
    assert e.value.code == code


def test_validate_url_accepts_public_http_and_https():
    assert validate_url("https://example.com/a?b=1") == "https://example.com/a?b=1"
    assert validate_url("http://example.com:80/") == "http://example.com:80/"


async def test_resolver_rejects_names_pointing_at_private_space(monkeypatch):
    async def fake_getaddrinfo(host, *a, **k):
        return [(None, None, None, None, ("10.1.2.3", 0)), (None, None, None, None, ("8.8.8.8", 0))]

    import asyncio

    monkeypatch.setattr(asyncio.get_running_loop(), "getaddrinfo", fake_getaddrinfo)
    # ANY private answer poisons the name (DNS rebinding / split-horizon).
    assert await lps._resolve_is_public("evil.example") is False


# --------------------------------------------------------------------------- #
# Extraction (pure)
# --------------------------------------------------------------------------- #
def test_extract_metadata_prefers_open_graph_and_absolutises_image():
    body = """<html><head><title>Fallback &amp; title</title>
    <meta property="og:title" content="NEJM — Sepsis update">
    <meta name="description" content="plain description">
    <meta property='og:description' content='OG description'>
    <meta property="og:site_name" content="NEJM">
    <meta property="og:image" content="/img/cover.png">
    </head><body>x</body></html>"""
    meta = extract_metadata(body, "https://www.nejm.org/doi/1")
    assert meta == {
        "title": "NEJM — Sepsis update",
        "description": "OG description",
        "site_name": "NEJM",
        "image_url": "https://www.nejm.org/img/cover.png",
    }


def test_extract_metadata_falls_back_to_title_and_description():
    body = "<html><head><title>  Just a\n title </title><meta name=description content=\"desc\"></head></html>"
    meta = extract_metadata(body, "https://example.com/")
    assert meta["title"] == "Just a title" and meta["description"] == "desc"
    assert meta["image_url"] is None and meta["site_name"] is None


# --------------------------------------------------------------------------- #
# Route
# --------------------------------------------------------------------------- #
class FakeFetcher:
    def __init__(self) -> None:
        self.pages: dict[str, Fetched] = {}
        self.calls: list[str] = []
        self.error: LinkPreviewError | None = None

    async def fetch(self, url: str, *, max_bytes: int) -> Fetched:
        self.calls.append(url)
        if self.error is not None:
            raise self.error
        page = self.pages.get(url)
        if page is None:
            raise LinkPreviewError("fetch_failed")
        if len(page.body) > max_bytes:
            raise LinkPreviewError("too_large")
        return page


@pytest.fixture
def fetcher(monkeypatch):
    fake = FakeFetcher()
    monkeypatch.setattr(lps, "fetcher", fake)
    return fake


HTML = b"""<html><head><title>Guideline</title>
<meta property="og:description" content="Sepsis bundle, 2026 revision">
<meta property="og:image" content="https://cdn.example.org/cover.png"></head></html>"""


async def test_preview_returns_metadata_inlines_image_and_caches(client, db, fetcher):
    me = await helpers.create_user(db)
    h = await helpers.auth_headers(me.id)
    fetcher.pages["https://example.org/guideline"] = Fetched(
        url="https://example.org/guideline?utm=1", content_type="text/html; charset=utf-8", body=HTML
    )
    fetcher.pages["https://cdn.example.org/cover.png"] = Fetched(
        url="https://cdn.example.org/cover.png", content_type="image/png", body=b"\x89PNG..."
    )
    r = await client.get(URL, params={"url": "https://example.org/guideline"}, headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["url"] == "https://example.org/guideline?utm=1"
    assert body["title"] == "Guideline"
    assert body["description"] == "Sepsis bundle, 2026 revision"
    assert body["image_data_url"] == "data:image/png;base64," + base64.b64encode(b"\x89PNG...").decode()
    assert fetcher.calls == ["https://example.org/guideline", "https://cdn.example.org/cover.png"]

    # Second call is served from Redis — the fetcher is not touched.
    r = await client.get(URL, params={"url": "https://example.org/guideline"}, headers=h)
    assert r.status_code == 200 and r.json() == body
    assert len(fetcher.calls) == 2
    # Audited by host only.
    rows = (
        await db.scalars(select(AuditLog).where(AuditLog.action == AuditAction.LINK_PREVIEW_FETCHED.value))
    ).all()
    assert len(rows) == 2 and rows[0].meta == {"host": "example.org"}


async def test_preview_without_image_or_with_oversized_image_still_works(client, db, fetcher):
    me = await helpers.create_user(db)
    h = await helpers.auth_headers(me.id)
    fetcher.pages["https://example.org/a"] = Fetched(
        url="https://example.org/a", content_type="text/html", body=HTML
    )
    fetcher.pages["https://cdn.example.org/cover.png"] = Fetched(
        url="https://cdn.example.org/cover.png", content_type="image/png", body=b"x" * (50 * 1024 + 1)
    )
    r = await client.get(URL, params={"url": "https://example.org/a"}, headers=h)
    assert r.status_code == 200 and r.json()["image_data_url"] is None
    assert r.json()["title"] == "Guideline"


async def test_preview_error_mapping(client, db, fetcher):
    me = await helpers.create_user(db)
    h = await helpers.auth_headers(me.id)
    # Guard failures are 422 before any fetch happens.
    for bad in ("http://127.0.0.1/", "ftp://x", "http://169.254.169.254/"):
        r = await client.get(URL, params={"url": bad}, headers=h)
        assert r.status_code == 422, bad
    assert fetcher.calls == []
    # Unreachable / non-HTML → 404.
    r = await client.get(URL, params={"url": "https://example.org/missing"}, headers=h)
    assert r.status_code == 404 and r.json()["detail"] == "fetch_failed"
    fetcher.pages["https://example.org/file.pdf"] = Fetched(
        url="https://example.org/file.pdf", content_type="application/pdf", body=b"%PDF"
    )
    r = await client.get(URL, params={"url": "https://example.org/file.pdf"}, headers=h)
    assert r.status_code == 404 and r.json()["detail"] == "not_html"
    # Too large → 422.
    fetcher.error = LinkPreviewError("too_large")
    r = await client.get(URL, params={"url": "https://example.org/huge"}, headers=h)
    assert r.status_code == 422 and r.json()["detail"] == "too_large"


async def test_preview_honours_privacy_flag_and_requires_auth(client, db, fetcher):
    me = await helpers.create_user(db)
    h = await helpers.auth_headers(me.id)
    db.add(UserPrivacySettings(user_id=me.id, link_previews=False))
    await db.commit()
    fetcher.pages["https://example.org/a"] = Fetched(
        url="https://example.org/a", content_type="text/html", body=HTML
    )
    r = await client.get(URL, params={"url": "https://example.org/a"}, headers=h)
    assert r.status_code == 403 and r.json()["detail"] == "link_previews_disabled"
    assert fetcher.calls == []
    r = await client.get(URL, params={"url": "https://example.org/a"})
    assert r.status_code == 401
