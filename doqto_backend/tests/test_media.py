"""Batch 5 — media: captions, video + poster thumb, server-side EXIF
stripping, voice waveform, presigned multipart upload flow, media gallery,
save/share export gate, polls, and the Batch 4 interplay (forward / delete /
purge) with the new types."""
from __future__ import annotations

import base64
import io
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from PIL import Image
from sqlalchemy import func, select

from app.api.ws_manager import ws_manager
from app.core.constants import (
    ORG_POLICY_ALLOW_MEDIA_EXPORT,
    UPLOAD_INLINE_MAX_BYTES,
    UPLOAD_PART_SIZE_BYTES,
)
from app.core.enums import (
    AuditAction,
    GroupMemberState,
    GroupRole,
    MessageType,
    OrgRole,
    TranscriptStatus,
    WsEventServer,
)
from app.core.security import encrypt_message
from app.models import (
    AuditLog,
    ConversationMember,
    ConversationPref,
    Group,
    GroupMember,
    Message,
    PollOption,
    PollVote,
    UploadIntent,
)
from app.services.image_service import has_exif, strip_image_metadata
from app.services.media_service import MediaService
from app.services.message_service import MessageService
from tests import helpers

MSGS = "/api/v1/messages"
CONVS = "/api/v1/conversations"
GPS_IFD = 0x8825
MODEL_TAG = 0x0110


# --------------------------------------------------------------------------- #
# fixtures / helpers
# --------------------------------------------------------------------------- #


@pytest.fixture
def ws_events(monkeypatch):
    events: list[tuple[str, list, dict]] = []

    async def fake_publish(user_ids, event, data):
        events.append((str(event), list(user_ids), data))

    monkeypatch.setattr(ws_manager, "publish_to_users", fake_publish)
    return events


def _of(ws_events, event: WsEventServer):
    return [(uids, d) for ev, uids, d in ws_events if ev == event.value]


def jpeg_with_gps(size=(8, 8)) -> bytes:
    """A JPEG carrying a device model and a GPS fix — what a phone camera emits."""
    img = Image.new("RGB", size, (200, 30, 30))
    exif = Image.Exif()
    exif[MODEL_TAG] = "Pixel 9"
    exif[GPS_IFD] = {1: "N", 2: (37.0, 46.0, 30.0), 3: "W", 4: (122.0, 25.0, 0.0)}
    buf = io.BytesIO()
    img.save(buf, "JPEG", exif=exif.tobytes())
    return buf.getvalue()


def _exif_of(data: bytes):
    e = Image.open(io.BytesIO(data)).getexif()
    return e.get(MODEL_TAG), dict(e.get_ifd(GPS_IFD))


async def _send(client, conv_id, headers, content="hello", **extra):
    r = await client.post(
        f"{CONVS}/{conv_id}/messages", json={"content": content, **extra}, headers=headers
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _upload(client, conv_id, headers, *, name="x.bin", data=b"bytes", ct="application/pdf", **form):
    r = await client.post(
        f"{MSGS}/upload/{conv_id}",
        files={"file": (name, data, ct)},
        data={k: str(v) for k, v in form.items() if v is not None},
        headers=headers,
    )
    return r


async def _poll(client, conv_id, headers, question="Lunch?", options=("Pizza", "Sushi"), multiple=False, **extra):
    r = await client.post(
        f"{CONVS}/{conv_id}/messages",
        json={
            "type": "poll",
            "poll": {"question": question, "options": list(options), "multiple": multiple},
            **extra,
        },
        headers=headers,
    )
    return r


async def _audit_count(db, action: AuditAction) -> int:
    return await db.scalar(
        select(func.count()).select_from(AuditLog).where(AuditLog.action == action.value)
    )


async def _make_admin(db, org):
    admin = await helpers.create_user(db, full_name="Dr Admin")
    await helpers.add_org_member(db, org, admin, role=OrgRole.ADMIN)
    return admin, await helpers.auth_headers(admin.id)


# --------------------------------------------------------------------------- #
# EXIF stripping (unit)
# --------------------------------------------------------------------------- #


def test_strip_jpeg_removes_gps_and_model_losslessly():
    data = jpeg_with_gps()
    assert has_exif(data)
    model, gps = _exif_of(data)
    assert model == "Pixel 9" and gps[2] == (37.0, 46.0, 30.0)

    clean = strip_image_metadata(data, "image/jpeg")
    assert not has_exif(clean)
    assert _exif_of(clean) == (None, {})
    assert b"Pixel 9" not in clean
    # Lossless: identical pixels, no re-encode.
    assert list(Image.open(io.BytesIO(clean)).getdata()) == list(
        Image.open(io.BytesIO(data)).getdata()
    )
    # Idempotent.
    assert strip_image_metadata(clean, "image/jpeg") == clean


def test_strip_png_drops_text_and_exif_chunks():
    from PIL.PngImagePlugin import PngInfo

    img = Image.new("RGB", (4, 4), (1, 2, 3))
    exif = Image.Exif()
    exif[GPS_IFD] = {1: "N", 2: (37.0, 46.0, 30.0)}
    info = PngInfo()
    info.add_text("Comment", "shot at the clinic")
    buf = io.BytesIO()
    img.save(buf, "PNG", pnginfo=info, exif=exif.tobytes())
    data = buf.getvalue()
    assert has_exif(data)
    clean = strip_image_metadata(data, "image/png")
    assert not has_exif(clean)
    assert Image.open(io.BytesIO(clean)).info == {}
    assert b"shot at the clinic" not in clean
    assert list(Image.open(io.BytesIO(clean)).getdata()) == list(img.getdata())


def test_strip_other_formats_reencode_or_passthrough():
    img = Image.new("RGB", (4, 4), (9, 9, 9))
    exif = Image.Exif()
    exif[MODEL_TAG] = "Pixel 9"
    buf = io.BytesIO()
    img.save(buf, "WEBP", exif=exif.tobytes())
    webp = buf.getvalue()
    assert Image.open(io.BytesIO(webp)).getexif().get(MODEL_TAG) == "Pixel 9"
    clean = strip_image_metadata(webp, "image/webp")
    assert Image.open(io.BytesIO(clean)).getexif().get(MODEL_TAG) is None
    # Not an image at all → unchanged.
    assert strip_image_metadata(b"%PDF-1.4 ...", "application/pdf") == b"%PDF-1.4 ..."
    assert strip_image_metadata(b"garbage", "image/heic") == b"garbage"


# --------------------------------------------------------------------------- #
# Inline upload: captions, EXIF, video + thumb, voice waveform
# --------------------------------------------------------------------------- #


async def test_inline_image_upload_strips_exif_and_stores_caption(client, chat, db, fake_s3, ws_events):
    data = jpeg_with_gps()
    r = await _upload(
        client, chat.conv.id, chat.alice_headers,
        name="scan.jpg", data=data, ct="image/jpeg", caption="Left knee, pre-op", width=8, height=8,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["type"] == "image" and body["caption"] == "Left knee, pre-op"
    assert body["media_width"] == 8 and body["media_height"] == 8
    stored = fake_s3.objects[body["s3_key"]]
    assert not has_exif(stored) and b"Pixel 9" not in stored
    assert body["file_size_bytes"] == len(stored) < len(data)
    # Caption is encrypted at rest.
    row = await db.get(Message, uuid.UUID(body["id"]))
    assert row.caption_encrypted and b"Left knee" not in row.caption_encrypted
    # Fan-out carries the caption.
    (uids, ev), = _of(ws_events, WsEventServer.NEW_MESSAGE)
    assert set(uids) == {chat.alice.id, chat.bob.id} and ev["caption"] == "Left knee, pre-op"
    # Chat list previews the caption.
    lst = await client.get(CONVS, headers=chat.bob_headers)
    conv = next(c for c in lst.json() if c["id"] == str(chat.conv.id))
    assert conv["last_message_preview"] == "Left knee, pre-op"
    assert conv["last_message_type"] == "image"


async def test_inline_video_upload_with_poster_thumb(client, chat, fake_s3):
    thumb = jpeg_with_gps((16, 9))
    r = await client.post(
        f"{MSGS}/upload/{chat.conv.id}",
        files={
            "file": ("clip.mp4", b"\x00" * 2048, "video/mp4"),
            "thumb": ("poster.jpg", thumb, "image/jpeg"),
        },
        data={"duration_sec": "12", "width": "1920", "height": "1080", "caption": "Gait"},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["type"] == "video" and body["voice_duration_sec"] == 12
    assert body["thumb_key"] and body["thumb_key"].startswith("thumbs/")
    assert body["caption"] == "Gait"
    assert not has_exif(fake_s3.objects[body["thumb_key"]])
    # Poster via file-url?thumb=1; the media itself without.
    r = await client.get(f"{MSGS}/{body['id']}/file-url", params={"thumb": "1"}, headers=chat.bob_headers)
    assert r.status_code == 200 and body["thumb_key"] in r.json()["url"]
    r = await client.get(f"{MSGS}/{body['id']}/file-url", headers=chat.bob_headers)
    assert body["s3_key"] in r.json()["url"]
    # A message with no thumb → 404 on the thumb URL.
    plain = await _upload(client, chat.conv.id, chat.alice_headers, name="a.pdf")
    r = await client.get(f"{MSGS}/{plain.json()['id']}/file-url", params={"thumb": "1"}, headers=chat.bob_headers)
    assert r.status_code == 404 and r.json()["detail"] == "file_not_found"


async def test_inline_upload_limits(client, chat, fake_s3):
    r = await _upload(client, chat.conv.id, chat.alice_headers, caption="x" * 1025)
    assert r.status_code == 422 and r.json()["detail"] == "caption_too_long"
    r = await _upload(client, chat.conv.id, chat.alice_headers, data=b"0" * (UPLOAD_INLINE_MAX_BYTES + 1))
    assert r.status_code == 413 and r.json()["detail"] == "file_too_large"
    r = await _upload(client, chat.conv.id, chat.alice_headers, name="v.mp4", ct="video/mp4", duration_sec=601)
    assert r.status_code == 422 and r.json()["detail"] == "video_too_long"
    # Thumb is ignored on a non-video and never stored.
    r = await client.post(
        f"{MSGS}/upload/{chat.conv.id}",
        files={"file": ("a.pdf", b"pdf", "application/pdf"), "thumb": ("p.jpg", b"jpg", "image/jpeg")},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200 and r.json()["thumb_key"] is None


async def test_voice_note_waveform_roundtrip_and_validation(client, chat, fake_s3):
    raw = bytes(range(64))
    r = await client.post(
        f"{MSGS}/voice-notes/{chat.conv.id}",
        files={"file": ("n.m4a", b"audio", "audio/mp4")},
        data={"duration_sec": "3", "transcript": "hi", "waveform": base64.b64encode(raw).decode(), "caption": "listen"},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert base64.b64decode(body["waveform"]) == raw and body["caption"] == "listen"
    # 65 bytes → 422; garbage → 422; none → null.
    for bad in (base64.b64encode(bytes(65)).decode(), "not*base64!"):
        r = await client.post(
            f"{MSGS}/voice-notes/{chat.conv.id}",
            files={"file": ("n.m4a", b"audio", "audio/mp4")},
            data={"duration_sec": "3", "waveform": bad},
            headers=chat.alice_headers,
        )
        assert r.status_code == 422 and r.json()["detail"] == "waveform_invalid"
    r = await client.post(
        f"{MSGS}/voice-notes/{chat.conv.id}",
        files={"file": ("n.m4a", b"audio", "audio/mp4")},
        data={"duration_sec": "3", "transcript": "x"},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200 and r.json()["waveform"] is None


# --------------------------------------------------------------------------- #
# Presigned multipart upload flow
# --------------------------------------------------------------------------- #


async def _intent(client, conv_id, headers, **body):
    payload = {"file_name": "big.mp4", "content_type": "video/mp4", "size_bytes": 1024}
    payload.update(body)
    return await client.post(f"{MSGS}/upload-intent/{conv_id}", json=payload, headers=headers)


async def test_upload_intent_small_file_single_put_then_complete(client, chat, db, fake_s3, ws_events):
    r = await _intent(client, chat.conv.id, chat.alice_headers, file_name="report.pdf", content_type="application/pdf", size_bytes=4096, client_id="ob-1")
    assert r.status_code == 200, r.text
    intent = r.json()
    assert intent["type"] == "file" and intent["put_url"] and intent["upload_id"] is None
    assert intent["part_urls"] == [] and intent["thumb_put_url"] is None
    assert intent["key"].startswith(f"files/{chat.org.id}/")
    # Nothing uploaded yet → complete is refused.
    r = await client.post(f"{MSGS}/upload-complete/{chat.conv.id}", json={"intent_id": intent["intent_id"]}, headers=chat.alice_headers)
    assert r.status_code == 409 and r.json()["detail"] == "upload_missing"
    # The client PUTs the bytes, then completes.
    fake_s3.put(intent["key"], b"%PDF" * 1024)
    r = await client.post(
        f"{MSGS}/upload-complete/{chat.conv.id}",
        json={"intent_id": intent["intent_id"], "caption": "Discharge summary"},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200, r.text
    msg = r.json()
    assert msg["type"] == "file" and msg["s3_key"] == intent["key"]
    assert msg["file_name"] == "report.pdf" and msg["file_size_bytes"] == 4096
    assert msg["caption"] == "Discharge summary" and msg["client_id"] == "ob-1"
    (uids, ev), = _of(ws_events, WsEventServer.NEW_MESSAGE)
    assert set(uids) == {chat.alice.id, chat.bob.id} and ev["id"] == msg["id"]
    assert await _audit_count(db, AuditAction.FILE_UPLOADED) == 1
    # Replaying complete (lost response) returns the same message, no second fan-out.
    r = await client.post(f"{MSGS}/upload-complete/{chat.conv.id}", json={"intent_id": intent["intent_id"]}, headers=chat.alice_headers)
    assert r.status_code == 200 and r.json()["id"] == msg["id"]
    assert len(_of(ws_events, WsEventServer.NEW_MESSAGE)) == 1
    # A new intent with the same client_id → the message, nothing to upload.
    r = await _intent(client, chat.conv.id, chat.alice_headers, client_id="ob-1")
    assert r.status_code == 200 and r.json()["message"]["id"] == msg["id"]
    assert await db.scalar(select(func.count()).select_from(Message)) == 1


async def test_upload_intent_multipart_video_with_thumb(client, chat, db, fake_s3, ws_events):
    size = UPLOAD_PART_SIZE_BYTES * 2 + 100  # 3 parts
    r = await _intent(client, chat.conv.id, chat.alice_headers, size_bytes=size, with_thumb=True)
    assert r.status_code == 200, r.text
    intent = r.json()
    assert intent["type"] == "video" and intent["put_url"] is None
    assert intent["upload_id"] and [p["part_number"] for p in intent["part_urls"]] == [1, 2, 3]
    assert intent["part_size"] == UPLOAD_PART_SIZE_BYTES and intent["thumb_put_url"]
    # Client uploads parts (we keep them small in the fake) + the poster.
    etags = [fake_s3.put_part(intent["upload_id"], n, bytes([n]) * 10) for n in (1, 2, 3)]
    thumb_key = intent["key"].replace("files/", "thumbs/").rsplit("/", 1)[0] + ".jpg"
    fake_s3.put(thumb_key, jpeg_with_gps((16, 9)))
    # Wrong part list → 422, multipart left open.
    r = await client.post(
        f"{MSGS}/upload-complete/{chat.conv.id}",
        json={"intent_id": intent["intent_id"], "parts": [{"part_number": 1, "etag": etags[0]}]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 422 and r.json()["detail"] == "upload_parts_invalid"
    r = await client.post(
        f"{MSGS}/upload-complete/{chat.conv.id}",
        json={
            "intent_id": intent["intent_id"],
            "parts": [{"part_number": n, "etag": e} for n, e in zip((1, 2, 3), etags)],
            "duration_sec": 42,
            "width": 1280,
            "height": 720,
            "has_thumb": True,
            "caption": "ROM check",
        },
        headers=chat.alice_headers,
    )
    assert r.status_code == 200, r.text
    msg = r.json()
    assert msg["type"] == "video" and msg["voice_duration_sec"] == 42
    assert msg["media_width"] == 1280 and msg["media_height"] == 720
    assert msg["thumb_key"] == thumb_key and msg["caption"] == "ROM check"
    assert fake_s3.objects[msg["s3_key"]] == b"\x01" * 10 + b"\x02" * 10 + b"\x03" * 10
    assert msg["file_size_bytes"] == 30  # the real object size, not the declared one
    assert not has_exif(fake_s3.objects[thumb_key])  # poster is scrubbed server-side
    assert intent["upload_id"] not in fake_s3.multipart
    row = await db.get(UploadIntent, uuid.UUID(intent["intent_id"]))
    assert row.completed_at is not None


async def test_upload_intent_image_is_exif_stripped_on_complete(client, chat, fake_s3):
    data = jpeg_with_gps()
    r = await _intent(client, chat.conv.id, chat.alice_headers, file_name="photo.jpg", content_type="image/jpeg", size_bytes=len(data))
    intent = r.json()
    fake_s3.put(intent["key"], data)
    r = await client.post(f"{MSGS}/upload-complete/{chat.conv.id}", json={"intent_id": intent["intent_id"]}, headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    assert r.json()["type"] == "image"
    assert not has_exif(fake_s3.objects[intent["key"]])
    assert intent["key"] in fake_s3.uploads  # re-uploaded clean


async def test_upload_intent_limits_and_gates(client, chat, db, fake_s3):
    # Declared too big → 413 before any S3 call.
    r = await _intent(client, chat.conv.id, chat.alice_headers, size_bytes=100 * 1024 * 1024 + 1)
    assert r.status_code == 413 and r.json()["detail"] == "file_too_large"
    assert fake_s3.multipart == {}
    # Thumb only for video.
    r = await _intent(client, chat.conv.id, chat.alice_headers, content_type="application/pdf", with_thumb=True)
    assert r.status_code == 422 and r.json()["detail"] == "thumb_not_allowed"
    # Outsider → 403 (conversation member check), unknown conv → 404.
    outsider = await helpers.create_user(db, full_name="Dr Out")
    out_h = await helpers.auth_headers(outsider.id)
    r = await _intent(client, chat.conv.id, out_h)
    assert r.status_code == 403
    r = await _intent(client, uuid.uuid4(), chat.alice_headers)
    assert r.status_code == 404
    # Actual object bigger than declared/allowed → object deleted, 413.
    r = await _intent(client, chat.conv.id, chat.alice_headers, size_bytes=1000)
    intent = r.json()
    fake_s3.put(intent["key"], b"x", size=100 * 1024 * 1024 + 1)
    r = await client.post(f"{MSGS}/upload-complete/{chat.conv.id}", json={"intent_id": intent["intent_id"]}, headers=chat.alice_headers)
    assert r.status_code == 413 and intent["key"] in fake_s3.deleted
    # Someone else's intent → 404 (no oracle); unknown intent → 404.
    r = await _intent(client, chat.conv.id, chat.alice_headers)
    intent = r.json()
    fake_s3.put(intent["key"], b"x" * 10)
    r = await client.post(f"{MSGS}/upload-complete/{chat.conv.id}", json={"intent_id": intent["intent_id"]}, headers=chat.bob_headers)
    assert r.status_code == 404 and r.json()["detail"] == "upload_intent_not_found"
    r = await client.post(f"{MSGS}/upload-complete/{chat.conv.id}", json={"intent_id": str(uuid.uuid4())}, headers=chat.alice_headers)
    assert r.status_code == 404
    # Expired intent → 409.
    row = await db.get(UploadIntent, uuid.UUID(intent["intent_id"]))
    row.expires_at = datetime.now(tz=timezone.utc) - timedelta(seconds=1)
    await db.commit()
    r = await client.post(f"{MSGS}/upload-complete/{chat.conv.id}", json={"intent_id": intent["intent_id"]}, headers=chat.alice_headers)
    assert r.status_code == 409 and r.json()["detail"] == "upload_intent_expired"
    # Video too long → 422.
    r = await _intent(client, chat.conv.id, chat.alice_headers)
    intent = r.json()
    fake_s3.put(intent["key"], b"x" * 10)
    r = await client.post(f"{MSGS}/upload-complete/{chat.conv.id}", json={"intent_id": intent["intent_id"], "duration_sec": 601}, headers=chat.alice_headers)
    assert r.status_code == 422 and r.json()["detail"] == "video_too_long"


async def test_purge_intents_aborts_abandoned_multipart(client, chat, db, fake_s3):
    r = await _intent(client, chat.conv.id, chat.alice_headers, size_bytes=UPLOAD_PART_SIZE_BYTES * 3, with_thumb=True)
    big = r.json()
    r = await _intent(client, chat.conv.id, chat.alice_headers, size_bytes=10)
    small = r.json()
    for iid in (big["intent_id"], small["intent_id"]):
        row = await db.get(UploadIntent, uuid.UUID(iid))
        row.expires_at = datetime.now(tz=timezone.utc) - timedelta(minutes=1)
    await db.commit()
    stale = await MediaService.purge_intents(db)
    await db.commit()
    assert sorted(stale) == sorted(
        [(big["key"], big["upload_id"], big["key"].replace("files/", "thumbs/").rsplit("/", 1)[0] + ".jpg"), (small["key"], None, None)]
    )
    assert await db.scalar(select(func.count()).select_from(UploadIntent)) == 0


# --------------------------------------------------------------------------- #
# Media gallery
# --------------------------------------------------------------------------- #


async def test_media_gallery_tabs_cursor_hides_and_clear(client, chat, db, fake_s3):
    h = chat.alice_headers
    imgs = [(await _upload(client, chat.conv.id, h, name=f"p{i}.jpg", data=b"img", ct="image/jpeg")).json() for i in range(3)]
    vid = (await _upload(client, chat.conv.id, h, name="v.mp4", data=b"vid", ct="video/mp4")).json()
    doc = (await _upload(client, chat.conv.id, chat.bob_headers, name="d.pdf")).json()
    await _send(client, chat.conv.id, h, "see https://pubmed.ncbi.nlm.nih.gov/123 and http://x.org/a, ok?")
    await _send(client, chat.conv.id, chat.bob_headers, "no links here")
    link2 = await _send(client, chat.conv.id, chat.bob_headers, "https://doqto.ai/")

    async def tab(t, headers=h, **q):
        r = await client.get(f"{CONVS}/{chat.conv.id}/media", params={"type": t, **q}, headers=headers)
        assert r.status_code == 200, r.text
        return r.json()

    page = await tab("image")
    assert [i["message"]["id"] for i in page["data"]] == [m["id"] for m in reversed(imgs)]
    assert page["next_cursor"] is None and all(i["urls"] == [] for i in page["data"])
    assert [i["message"]["id"] for i in (await tab("video"))["data"]] == [vid["id"]]
    assert [i["message"]["id"] for i in (await tab("file"))["data"]] == [doc["id"]]
    links = await tab("link")
    assert [i["message"]["id"] for i in links["data"]][0] == link2["id"]
    assert links["data"][1]["urls"] == ["https://pubmed.ncbi.nlm.nih.gov/123", "http://x.org/a"]
    assert len(links["data"]) == 2
    # Paging by seq cursor.
    p1 = await tab("image", limit=2)
    assert len(p1["data"]) == 2 and p1["next_cursor"] == str(p1["data"][-1]["message"]["seq"])
    p2 = await tab("image", limit=2, cursor=p1["next_cursor"])
    assert [i["message"]["id"] for i in p2["data"]] == [imgs[0]["id"]] and p2["next_cursor"] is None
    # Hidden ("delete for me") rows are gone for me, not for Bob.
    r = await client.post(f"{MSGS}/hide", json={"message_ids": [imgs[2]["id"]]}, headers=h)
    assert r.status_code == 200
    assert len((await tab("image"))["data"]) == 2
    assert len((await tab("image", headers=chat.bob_headers))["data"]) == 3
    # Clear chat up to the videos's seq → only newer media remains for Alice.
    db.add(ConversationPref(conversation_id=chat.conv.id, user_id=chat.alice.id, cleared_before_seq=vid["seq"]))
    await db.commit()
    assert (await tab("image"))["data"] == [] and (await tab("video"))["data"] == []
    assert len((await tab("file"))["data"]) == 1
    # Deleted-for-everyone media disappears for all.
    r = await client.delete(f"{MSGS}/{doc['id']}", headers=chat.bob_headers)
    assert r.status_code == 200
    assert (await tab("file", headers=chat.bob_headers))["data"] == []
    # Validation + gates.
    r = await client.get(f"{CONVS}/{chat.conv.id}/media", params={"type": "gif"}, headers=h)
    assert r.status_code == 422
    r = await client.get(f"{CONVS}/{chat.conv.id}/media", params={"type": "image", "cursor": "abc"}, headers=h)
    assert r.status_code == 400
    outsider = await helpers.create_user(db, full_name="Dr Out")
    r = await client.get(f"{CONVS}/{chat.conv.id}/media", headers=await helpers.auth_headers(outsider.id))
    assert r.status_code == 403
    assert await _audit_count(db, AuditAction.CONVERSATION_ACCESSED) >= 1


# --------------------------------------------------------------------------- #
# Export gate (Save to Photos / share)
# --------------------------------------------------------------------------- #


async def test_export_audit_follows_org_policy(client, chat, db, fake_s3):
    img = (await _upload(client, chat.conv.id, chat.alice_headers, name="p.jpg", data=b"i", ct="image/jpeg")).json()
    text = await _send(client, chat.conv.id, chat.alice_headers)
    url = f"{MSGS}/{img['id']}/export-audit"
    # Org chat, default policy off → blocked, and the flag says so.
    r = await client.post(url, headers=chat.bob_headers)
    assert r.status_code == 403 and r.json()["detail"] == "media_export_blocked"
    lst = await client.get(CONVS, headers=chat.bob_headers)
    assert next(c for c in lst.json() if c["id"] == str(chat.conv.id))["media_export_allowed"] is False
    assert await _audit_count(db, AuditAction.FILE_EXPORTED) == 0
    # Admin enables it → allowed + audited.
    _, admin_h = await _make_admin(db, chat.org)
    r = await client.patch(
        f"/api/v1/orgs/{chat.org.id}/settings/networking",
        json={ORG_POLICY_ALLOW_MEDIA_EXPORT: True},
        headers=admin_h,
    )
    assert r.status_code == 200 and r.json()["policies"][ORG_POLICY_ALLOW_MEDIA_EXPORT] is True
    r = await client.post(url, headers=chat.bob_headers)
    assert r.status_code == 200
    assert await _audit_count(db, AuditAction.FILE_EXPORTED) == 1
    lst = await client.get(CONVS, headers=chat.bob_headers)
    assert next(c for c in lst.json() if c["id"] == str(chat.conv.id))["media_export_allowed"] is True
    # Not media → 404; outsider → 404 (same as unknown).
    r = await client.post(f"{MSGS}/{text['id']}/export-audit", headers=chat.bob_headers)
    assert r.status_code == 404 and r.json()["detail"] == "file_not_found"
    outsider = await helpers.create_user(db, full_name="Dr Out")
    r = await client.post(url, headers=await helpers.auth_headers(outsider.id))
    assert r.status_code == 404 and r.json()["detail"] == "message_not_found"


async def test_export_in_network_chat_depends_on_own_orgs(client, db, fake_s3):
    """No org → may export. A member of an org that forbids it is bound by
    that policy even in a cross-org DM."""
    free = await helpers.create_user(db, full_name="Dr Free")
    peer = await helpers.create_user(db, full_name="Dr Peer")
    await helpers.connect_users(db, free, peer)
    free_h, peer_h = await helpers.auth_headers(free.id), await helpers.auth_headers(peer.id)
    r = await client.post(CONVS, json={"type": "direct", "member_ids": [str(peer.id)]}, headers=free_h)
    assert r.status_code == 200, r.text
    conv = r.json()
    assert conv["org_id"] is None and conv["media_export_allowed"] is True
    img = (await _upload(client, conv["id"], free_h, name="p.jpg", data=b"i", ct="image/jpeg")).json()
    assert (await client.post(f"{MSGS}/{img['id']}/export-audit", headers=free_h)).status_code == 200
    assert (await client.post(f"{MSGS}/{img['id']}/export-audit", headers=peer_h)).status_code == 200
    # Peer joins an org (policy default off) → blocked for peer, still fine for free.
    org = await helpers.create_org(db, name="Strict Clinic")
    await helpers.add_org_member(db, org, peer)
    assert (await client.post(f"{MSGS}/{img['id']}/export-audit", headers=peer_h)).status_code == 403
    assert (await client.post(f"{MSGS}/{img['id']}/export-audit", headers=free_h)).status_code == 200
    lst = await client.get(CONVS, headers=peer_h)
    assert next(c for c in lst.json() if c["id"] == conv["id"])["media_export_allowed"] is False


# --------------------------------------------------------------------------- #
# Polls
# --------------------------------------------------------------------------- #


async def test_poll_create_validation_and_shape(client, chat, db, ws_events):
    r = await _poll(client, chat.conv.id, chat.alice_headers, options=("Only one",))
    assert r.status_code == 422
    r = await _poll(client, chat.conv.id, chat.alice_headers, options=("A", "a"))
    assert r.status_code == 422
    r = await _poll(client, chat.conv.id, chat.alice_headers, options=tuple(str(i) for i in range(13)))
    assert r.status_code == 422
    r = await client.post(f"{CONVS}/{chat.conv.id}/messages", json={"type": "poll"}, headers=chat.alice_headers)
    assert r.status_code == 422
    r = await client.post(f"{CONVS}/{chat.conv.id}/messages", json={"type": "image", "content": "x"}, headers=chat.alice_headers)
    assert r.status_code == 422
    r = await client.post(f"{CONVS}/{chat.conv.id}/messages", json={"type": "text"}, headers=chat.alice_headers)
    assert r.status_code == 422

    r = await _poll(client, chat.conv.id, chat.alice_headers, question=" Lunch? ", options=(" Pizza ", "Sushi", "Salad"), client_id="poll-1")
    assert r.status_code == 200, r.text
    msg = r.json()
    assert msg["type"] == "poll" and msg["content"] == "Lunch?" and msg["client_id"] == "poll-1"
    poll = msg["poll"]
    assert poll["question"] == "Lunch?" and poll["multiple"] is False and poll["voter_count"] == 0
    assert [o["text"] for o in poll["options"]] == ["Pizza", "Sushi", "Salad"]
    assert [o["position"] for o in poll["options"]] == [0, 1, 2]
    assert all(o["vote_count"] == 0 and o["voter_ids"] == [] for o in poll["options"])
    (uids, ev), = _of(ws_events, WsEventServer.NEW_MESSAGE)
    assert ev["poll"]["options"][0]["text"] == "Pizza"
    # Idempotent on client_id.
    r = await _poll(client, chat.conv.id, chat.alice_headers, client_id="poll-1")
    assert r.json()["id"] == msg["id"]
    assert await db.scalar(select(func.count()).select_from(PollOption)) == 3
    # Encrypted at rest.
    opt = (await db.execute(select(PollOption))).scalars().first()
    assert b"Pizza" not in opt.text_encrypted and b"Sushi" not in opt.text_encrypted
    row = await db.get(Message, uuid.UUID(msg["id"]))
    assert b"Lunch" not in row.content_encrypted
    # Chat list preview + reply quote show the question.
    lst = await client.get(CONVS, headers=chat.bob_headers)
    conv = next(c for c in lst.json() if c["id"] == str(chat.conv.id))
    assert conv["last_message_preview"] == "Lunch?" and conv["last_message_type"] == "poll"
    reply = await _send(client, chat.conv.id, chat.bob_headers, "voting now", reply_to_id=msg["id"])
    assert reply["reply_to"]["type"] == "poll" and reply["reply_to"]["preview"] == "Lunch?"


async def test_poll_vote_unvote_events_and_visibility(client, chat, db, ws_events):
    msg = (await _poll(client, chat.conv.id, chat.alice_headers)).json()
    pizza, sushi = (o["id"] for o in msg["poll"]["options"])
    ws_events.clear()
    url = f"{MSGS}/{msg['id']}/vote"

    # Single-choice: two ids → 422; unknown option → 422.
    r = await client.put(url, json={"option_ids": [pizza, sushi]}, headers=chat.bob_headers)
    assert r.status_code == 422 and r.json()["detail"] == "poll_single_choice"
    r = await client.put(url, json={"option_ids": [str(uuid.uuid4())]}, headers=chat.bob_headers)
    assert r.status_code == 422 and r.json()["detail"] == "poll_option_invalid"
    assert ws_events == []

    r = await client.put(url, json={"option_ids": [pizza]}, headers=chat.bob_headers)
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["poll"]["voter_count"] == 1 and out["changed_at"] is not None
    assert out["poll"]["options"][0]["voter_ids"] == [str(chat.bob.id)]
    (uids, ev), = _of(ws_events, WsEventServer.POLL_UPDATED)
    assert set(uids) == {chat.alice.id, chat.bob.id}
    assert ev["message_id"] == msg["id"] and ev["actor_id"] == str(chat.bob.id)
    assert ev["poll"]["options"][0]["vote_count"] == 1 and ev["changed_at"] == out["changed_at"]
    # Same selection again → no event.
    r = await client.put(url, json={"option_ids": [pizza]}, headers=chat.bob_headers)
    assert r.status_code == 200 and len(_of(ws_events, WsEventServer.POLL_UPDATED)) == 1
    # Switching replaces the earlier vote.
    r = await client.put(url, json={"option_ids": [sushi]}, headers=chat.bob_headers)
    counts = [o["vote_count"] for o in r.json()["poll"]["options"]]
    assert counts == [0, 1] and len(_of(ws_events, WsEventServer.POLL_UPDATED)) == 2
    # Alice votes too; everyone sees everyone's votes on read.
    await client.put(url, json={"option_ids": [sushi]}, headers=chat.alice_headers)
    page = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    row = next(m for m in page.json() if m["id"] == msg["id"])
    assert row["poll"]["voter_count"] == 2
    assert set(row["poll"]["options"][1]["voter_ids"]) == {str(chat.alice.id), str(chat.bob.id)}
    # changed_since catch-up picks the poll up.
    since = (datetime.now(tz=timezone.utc) - timedelta(minutes=5)).isoformat()
    page = await client.get(f"{CONVS}/{chat.conv.id}/messages", params={"changed_since": since}, headers=chat.bob_headers)
    assert msg["id"] in {m["id"] for m in page.json()}
    # Unvote: event; second unvote: no-op.
    ws_events.clear()
    r = await client.delete(url, headers=chat.bob_headers)
    assert r.status_code == 200 and r.json()["poll"]["voter_count"] == 1
    assert len(_of(ws_events, WsEventServer.POLL_UPDATED)) == 1
    r = await client.delete(url, headers=chat.bob_headers)
    assert r.status_code == 200 and len(_of(ws_events, WsEventServer.POLL_UPDATED)) == 1
    assert await _audit_count(db, AuditAction.POLL_VOTED) == 4
    # Gates: outsider → 404; a text message → 422; not a member of conv → 404.
    outsider = await helpers.create_user(db, full_name="Dr Out")
    r = await client.put(url, json={"option_ids": [pizza]}, headers=await helpers.auth_headers(outsider.id))
    assert r.status_code == 404 and r.json()["detail"] == "message_not_found"
    text = await _send(client, chat.conv.id, chat.alice_headers)
    r = await client.put(f"{MSGS}/{text['id']}/vote", json={"option_ids": [pizza]}, headers=chat.bob_headers)
    assert r.status_code == 422 and r.json()["detail"] == "not_a_poll"


async def test_poll_multiple_choice(client, chat, ws_events):
    msg = (await _poll(client, chat.conv.id, chat.alice_headers, options=("A", "B", "C"), multiple=True)).json()
    a, b, c = (o["id"] for o in msg["poll"]["options"])
    r = await client.put(f"{MSGS}/{msg['id']}/vote", json={"option_ids": [a, c, a]}, headers=chat.bob_headers)
    assert r.status_code == 200, r.text
    assert [o["vote_count"] for o in r.json()["poll"]["options"]] == [1, 0, 1]
    assert r.json()["poll"]["voter_count"] == 1
    # Changing to a subset drops the rest.
    r = await client.put(f"{MSGS}/{msg['id']}/vote", json={"option_ids": [b]}, headers=chat.bob_headers)
    assert [o["vote_count"] for o in r.json()["poll"]["options"]] == [0, 1, 0]


async def test_poll_not_forwardable_and_delete_shreds_rows(client, chat, db, ws_events):
    msg = (await _poll(client, chat.conv.id, chat.alice_headers)).json()
    pizza = msg["poll"]["options"][0]["id"]
    await client.put(f"{MSGS}/{msg['id']}/vote", json={"option_ids": [pizza]}, headers=chat.bob_headers)
    r = await client.post(f"{MSGS}/{msg['id']}/forward", json={"conversation_ids": [str(chat.conv.id)]}, headers=chat.alice_headers)
    assert r.status_code == 409 and r.json()["detail"] == "message_not_forwardable"
    # Deleting a poll with a vote on it must work and leave no option/vote rows.
    r = await client.delete(f"{MSGS}/{msg['id']}", headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    assert r.json()["deleted_at"] and r.json()["poll"] is None and r.json()["content"] is None
    assert await db.scalar(select(func.count()).select_from(PollOption)) == 0
    assert await db.scalar(select(func.count()).select_from(PollVote)) == 0
    # Voting on a tombstone → 409.
    r = await client.put(f"{MSGS}/{msg['id']}/vote", json={"option_ids": [pizza]}, headers=chat.bob_headers)
    assert r.status_code == 409 and r.json()["detail"] == "message_deleted"


async def test_member_leaving_group_takes_votes_along(client, db, ws_events):
    owner = await helpers.create_user(db, full_name="Dr Owner")
    peer = await helpers.create_user(db, full_name="Dr Peer")
    third = await helpers.create_user(db, full_name="Dr Third")
    owner_h = await helpers.auth_headers(owner.id)
    peer_h = await helpers.auth_headers(peer.id)
    third_h = await helpers.auth_headers(third.id)
    r = await client.post(
        "/api/v1/groups",
        json={"name": "Rounds", "post_policy": "all_members", "member_dm_policy": "request"},
        headers=owner_h,
    )
    assert r.status_code == 201, r.text
    g = r.json()
    group = await db.scalar(select(Group).where(Group.id == uuid.UUID(g["id"])))
    for u in (peer, third):
        db.add(GroupMember(group_id=group.id, user_id=u.id, role=GroupRole.MEMBER, state=GroupMemberState.ACTIVE))
        db.add(ConversationMember(conversation_id=group.conversation_id, user_id=u.id))
    group.member_count += 2
    await db.commit()
    conv_id = g["conversation_id"]
    msg = (await _poll(client, conv_id, owner_h)).json()
    pizza = msg["poll"]["options"][0]["id"]
    for h in (peer_h, third_h):
        assert (await client.put(f"{MSGS}/{msg['id']}/vote", json={"option_ids": [pizza]}, headers=h)).status_code == 200
    ws_events.clear()
    r = await client.delete(f"/api/v1/groups/{g['id']}/members/{peer.id}", headers=peer_h)
    assert r.status_code == 200, r.text
    (uids, ev), = _of(ws_events, WsEventServer.POLL_UPDATED)
    assert set(uids) == {owner.id, third.id}
    assert ev["poll"]["options"][0]["voter_ids"] == [str(third.id)] and ev["actor_id"] == str(peer.id)
    page = await client.get(f"{CONVS}/{conv_id}/messages", headers=owner_h)
    row = next(m for m in page.json() if m["id"] == msg["id"])
    assert row["poll"]["voter_count"] == 1 and row["changed_at"] is not None


# --------------------------------------------------------------------------- #
# Batch 4 interplay: forward copies caption + thumb; delete + purge shred them
# --------------------------------------------------------------------------- #


async def test_forward_video_copies_caption_thumb_and_dims(client, chat, db, fake_s3, ws_events):
    carol = await helpers.create_user(db, full_name="Dr Carol")
    await helpers.add_org_member(db, chat.org, carol)
    other = await helpers.create_conversation(db, chat.org, [chat.alice, carol])
    r = await client.post(
        f"{MSGS}/upload/{chat.conv.id}",
        files={"file": ("c.mp4", b"vid", "video/mp4"), "thumb": ("p.jpg", jpeg_with_gps(), "image/jpeg")},
        data={"duration_sec": "7", "caption": "Pre-op gait", "width": "640", "height": "480"},
        headers=chat.alice_headers,
    )
    src = r.json()
    r = await client.post(f"{MSGS}/{src['id']}/forward", json={"conversation_ids": [str(other.id)]}, headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    (copy,) = r.json()
    assert copy["type"] == "video" and copy["caption"] == "Pre-op gait"
    assert copy["voice_duration_sec"] == 7 and (copy["media_width"], copy["media_height"]) == (640, 480)
    assert copy["thumb_key"] and copy["thumb_key"] != src["thumb_key"]
    assert copy["s3_key"] != src["s3_key"]
    assert set(fake_s3.copied) == {(src["s3_key"], copy["s3_key"]), (src["thumb_key"], copy["thumb_key"])}
    # Deleting the copy removes both of ITS objects, never the source's.
    r = await client.delete(f"{MSGS}/{copy['id']}", headers=chat.alice_headers)
    assert r.status_code == 200
    assert set(fake_s3.deleted) == {copy["s3_key"], copy["thumb_key"]}
    assert r.json()["caption"] is None and r.json()["thumb_key"] is None
    row = await db.get(Message, uuid.UUID(copy["id"]))
    assert row.caption_encrypted is None and row.thumb_key is None and row.waveform is None


async def test_purge_content_shreds_thumbs_captions_waveform_and_polls(chat, db):
    old = datetime.now(tz=timezone.utc) - timedelta(days=31)
    video = Message(
        conversation_id=chat.conv.id, sender_id=chat.alice.id, type=MessageType.VIDEO, seq=1,
        transcript_status=TranscriptStatus.NONE, is_deleted=True, created_at=old,
        s3_key="files/o/1/c.mp4", thumb_key="thumbs/o/1.jpg",
        caption_encrypted=encrypt_message("cap"), waveform=b"\x01\x02",
    )
    poll = Message(
        conversation_id=chat.conv.id, sender_id=chat.alice.id, type=MessageType.POLL, seq=2,
        transcript_status=TranscriptStatus.NONE, is_deleted=True, created_at=old,
        content_encrypted=encrypt_message("q?"), poll_multiple=False,
    )
    db.add_all([video, poll])
    await db.flush()
    db.add(PollOption(message_id=poll.id, position=0, text_encrypted=encrypt_message("a")))
    db.add(PollOption(message_id=poll.id, position=1, text_encrypted=encrypt_message("b")))
    await db.commit()
    keys = await MessageService.purge_content(db)
    await db.commit()
    assert sorted(keys) == ["files/o/1/c.mp4", "thumbs/o/1.jpg"]
    await db.refresh(video)
    assert video.thumb_key is None and video.caption_encrypted is None and video.waveform is None
    assert await db.scalar(select(func.count()).select_from(PollOption)) == 0


async def test_org_policy_patch_rejects_non_admin_and_lists_media_export_default(client, chat):
    r = await client.patch(
        f"/api/v1/orgs/{chat.org.id}/settings/networking",
        json={ORG_POLICY_ALLOW_MEDIA_EXPORT: True},
        headers=chat.alice_headers,
    )
    assert r.status_code == 403
    mine = await client.get("/api/v1/orgs/mine", headers=chat.alice_headers)
    assert mine.status_code == 200
    orgs = mine.json() if isinstance(mine.json(), list) else [mine.json()]
    assert orgs[0]["policies"][ORG_POLICY_ALLOW_MEDIA_EXPORT] is False
