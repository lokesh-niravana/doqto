from __future__ import annotations

import uuid

from app.core.constants import PRESIGNED_URL_TTL_SECONDS, UPLOAD_URL_TTL_SEC
from app.services.s3_client import RealS3Client

_s3_instance = RealS3Client()


class FileService:
    @staticmethod
    def key_for_file(*, org_id: uuid.UUID, message_id: uuid.UUID, filename: str) -> str:
        return f"files/{org_id}/{message_id}/{filename}"

    @staticmethod
    def key_for_voice_note(*, org_id: uuid.UUID, message_id: uuid.UUID) -> str:
        return f"voice-notes/{org_id}/{message_id}.m4a"

    # Network (cross-org) conversations have no owning org, so their objects
    # are namespaced by conversation id instead of org id (A2). Crypto-shred
    # purge still collects these keys off the message row like any other.
    @staticmethod
    def key_for_network_file(
        *, conversation_id: uuid.UUID, message_id: uuid.UUID, filename: str
    ) -> str:
        return f"files/network/{conversation_id}/{message_id}/{filename}"

    @staticmethod
    def key_for_network_voice_note(
        *, conversation_id: uuid.UUID, message_id: uuid.UUID
    ) -> str:
        return f"voice-notes/network/{conversation_id}/{message_id}.m4a"

    @staticmethod
    def key_for_avatar(*, user_id: uuid.UUID, filename: str) -> str:
        return f"avatars/{user_id}/{filename}"

    # Poster thumbnail of a video (batch 5) — sits next to the media object.
    @staticmethod
    def key_for_thumb(*, org_id: uuid.UUID, message_id: uuid.UUID) -> str:
        return f"thumbs/{org_id}/{message_id}.jpg"

    @staticmethod
    def key_for_network_thumb(*, conversation_id: uuid.UUID, message_id: uuid.UUID) -> str:
        return f"thumbs/network/{conversation_id}/{message_id}.jpg"

    @staticmethod
    def media_key(
        *,
        org_id: uuid.UUID | None,
        conversation_id: uuid.UUID,
        message_id: uuid.UUID,
        filename: str,
    ) -> str:
        """files/… key for an image / video / document, org- or network-scoped."""
        if org_id is None:
            return FileService.key_for_network_file(
                conversation_id=conversation_id, message_id=message_id, filename=filename
            )
        return FileService.key_for_file(org_id=org_id, message_id=message_id, filename=filename)

    @staticmethod
    def thumb_key(
        *, org_id: uuid.UUID | None, conversation_id: uuid.UUID, message_id: uuid.UUID
    ) -> str:
        if org_id is None:
            return FileService.key_for_network_thumb(
                conversation_id=conversation_id, message_id=message_id
            )
        return FileService.key_for_thumb(org_id=org_id, message_id=message_id)

    @staticmethod
    async def upload_bytes(*, key: str, data: bytes, content_type: str) -> str:
        await _s3_instance.upload_bytes(key=key, data=data, content_type=content_type)
        return key

    @staticmethod
    async def presigned_url(*, key: str, expires_in: int = PRESIGNED_URL_TTL_SECONDS) -> str:
        return await _s3_instance.presigned_url(key=key, expires_in=expires_in)

    @staticmethod
    async def copy_object(*, src_key: str, dst_key: str) -> None:
        await _s3_instance.copy_object(src_key=src_key, dst_key=dst_key)

    @staticmethod
    async def delete_object(*, key: str) -> None:
        await _s3_instance.delete_object(key=key)

    # --- Presigned uploads (batch 5) ---------------------------------------- #

    @staticmethod
    async def presigned_put(*, key: str, content_type: str, expires_in: int = UPLOAD_URL_TTL_SEC) -> str:
        return await _s3_instance.presigned_put(key=key, content_type=content_type, expires_in=expires_in)

    @staticmethod
    async def create_multipart_upload(*, key: str, content_type: str) -> str:
        return await _s3_instance.create_multipart_upload(key=key, content_type=content_type)

    @staticmethod
    async def presigned_upload_part(
        *, key: str, upload_id: str, part_number: int, expires_in: int = UPLOAD_URL_TTL_SEC
    ) -> str:
        return await _s3_instance.presigned_upload_part(
            key=key, upload_id=upload_id, part_number=part_number, expires_in=expires_in
        )

    @staticmethod
    async def complete_multipart_upload(
        *, key: str, upload_id: str, parts: list[tuple[int, str]]
    ) -> None:
        await _s3_instance.complete_multipart_upload(key=key, upload_id=upload_id, parts=parts)

    @staticmethod
    async def abort_multipart_upload(*, key: str, upload_id: str) -> None:
        await _s3_instance.abort_multipart_upload(key=key, upload_id=upload_id)

    @staticmethod
    async def head_object(*, key: str) -> dict | None:
        return await _s3_instance.head_object(key=key)

    @staticmethod
    async def get_object(*, key: str) -> bytes:
        return await _s3_instance.get_object(key=key)
