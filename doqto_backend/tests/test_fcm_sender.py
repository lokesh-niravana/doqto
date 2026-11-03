"""FcmPushSender: request shape + dead-token detection (no network)."""
from __future__ import annotations

import json

import httpx
import pytest

from app.core.config import settings
from app.services import push_service
from app.services.push_service import PushResult

def _fake_sa() -> dict:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    pem = rsa.generate_private_key(public_exponent=65537, key_size=2048).private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    return {
        "type": "service_account",
        "project_id": "doqto-test",
        "private_key_id": "k",
        "private_key": pem.decode(),
        "client_email": "x@doqto-test.iam.gserviceaccount.com",
        "client_id": "1",
        "token_uri": "https://oauth2.googleapis.com/token",
    }


@pytest.fixture
def sender(monkeypatch):
    monkeypatch.setattr(settings, "FCM_PROJECT_ID", "doqto-test")
    monkeypatch.setattr(settings, "FCM_SERVICE_ACCOUNT_JSON", json.dumps(_fake_sa()))
    s = push_service.FcmPushSender()
    monkeypatch.setattr(s, "_bearer", lambda: "tok")
    return s


def _patch_http(monkeypatch, status, text, seen):
    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(status, text=text)

    real = httpx.AsyncClient

    def factory(**kw):
        return real(transport=httpx.MockTransport(handler), **kw)

    monkeypatch.setattr(push_service.httpx, "AsyncClient", factory)


async def test_send_shapes_v1_message(monkeypatch, sender):
    seen: list[httpx.Request] = []
    _patch_http(monkeypatch, 200, "{}", seen)
    ok = await sender.send(
        token="t1", title="Doqto", body="New message", data={"conversation_id": "c"}, collapse_key="c"
    )
    assert ok is PushResult.SENT
    req = seen[0]
    assert req.url.path == "/v1/projects/doqto-test/messages:send"
    assert req.headers["authorization"] == "Bearer tok"
    m = json.loads(req.content)["message"]
    assert m["token"] == "t1" and m["data"] == {"conversation_id": "c"}
    assert m["apns"]["headers"]["apns-collapse-id"] == "c"


async def test_unregistered_token_is_pruned(monkeypatch, sender):
    _patch_http(monkeypatch, 404, '{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}', [])
    assert await sender.send(token="t", title="a", body="b", data={}, collapse_key="k") is PushResult.DEAD


async def test_transient_error_keeps_token(monkeypatch, sender):
    _patch_http(monkeypatch, 503, "unavailable", [])
    assert await sender.send(token="t", title="a", body="b", data={}, collapse_key="k") is PushResult.FAILED


async def test_bad_apns_credential_is_a_failure_with_its_reason(monkeypatch, sender, caplog):
    """The prod failure of 2026-11-03: FCM 401 because the APNs key in
    Firebase belonged to the old Apple team. Keep the token; say why."""
    body = '{"error":{"code":401,"message":"Invalid APNs credential.","status":"UNAUTHENTICATED"}}'
    _patch_http(monkeypatch, 401, body, [])
    with caplog.at_level("WARNING", logger="doqto.push"):
        r = await sender.send(token="t", title="a", body="b", data={}, collapse_key="k")
    assert r is PushResult.FAILED
    assert "UNAUTHENTICATED: Invalid APNs credential." in caplog.text


def test_bearer_refresh_transport_is_installed(monkeypatch):
    """Regression: google-auth's default transport needs `requests`; a missing
    dependency only showed up in prod on the first real push."""
    import google.auth.transport.requests  # noqa: F401

    monkeypatch.setattr(settings, "FCM_PROJECT_ID", "doqto-test")
    monkeypatch.setattr(settings, "FCM_SERVICE_ACCOUNT_JSON", json.dumps(_fake_sa()))
    s = push_service.FcmPushSender()
    monkeypatch.setattr(s._creds, "refresh", lambda req: setattr(s._creds, "token", "fresh"))
    assert s._bearer() == "fresh"
