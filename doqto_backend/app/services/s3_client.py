"""Real AWS S3 client using boto3. Creates the bucket on first use if it doesn't exist."""

from __future__ import annotations

import logging

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

from app.core.config import settings
from app.core.constants import PRESIGNED_URL_TTL_SECONDS

log = logging.getLogger("doqto.s3")

_client = None


def _get_client():
    global _client
    if _client is None:
        _client = boto3.client(
            "s3",
            region_name=settings.AWS_REGION,
            # Blank keys → boto3 default chain (ECS task role in prod).
            aws_access_key_id=settings.AWS_ACCESS_KEY_ID or None,
            aws_secret_access_key=settings.AWS_SECRET_ACCESS_KEY or None,
            config=Config(signature_version="s3v4"),
        )
        try:
            _ensure_bucket()
        except Exception as e:
            log.warning("[S3] bucket check failed (%s) — proceeding anyway", e)
    return _client


def _ensure_bucket() -> None:
    bucket = settings.AWS_S3_BUCKET_NAME
    try:
        _client.head_bucket(Bucket=bucket)
        log.info("[S3] bucket '%s' exists", bucket)
    except ClientError as e:
        error_code = str(e.response.get("Error", {}).get("Code", ""))
        if error_code in ("404", "NoSuchBucket", "400"):
            log.info("[S3] bucket '%s' not accessible (code=%s), attempting create in %s", bucket, error_code, settings.AWS_REGION)
            try:
                if settings.AWS_REGION == "us-east-1":
                    _client.create_bucket(Bucket=bucket)
                else:
                    _client.create_bucket(
                        Bucket=bucket,
                        CreateBucketConfiguration={"LocationConstraint": settings.AWS_REGION},
                    )
            except ClientError as create_err:
                if "BucketAlreadyOwnedByYou" in str(create_err) or "BucketAlreadyExists" in str(create_err):
                    log.info("[S3] bucket '%s' already exists", bucket)
                else:
                    raise
        else:
            raise
    # Best-effort hardening (HIPAA H6): default SSE + block all public access.
    # The bucket may pre-exist with stricter IAM that denies these calls —
    # never fail the boot path over it.
    try:
        _client.put_public_access_block(
            Bucket=bucket,
            PublicAccessBlockConfiguration={
                "BlockPublicAcls": True,
                "IgnorePublicAcls": True,
                "BlockPublicPolicy": True,
                "RestrictPublicBuckets": True,
            },
        )
        _client.put_bucket_encryption(
            Bucket=bucket,
            ServerSideEncryptionConfiguration={
                "Rules": [
                    {"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}
                ]
            },
        )
    except Exception as e:
        log.warning("[S3] bucket hardening skipped (%s)", e)


class RealS3Client:
    async def upload_bytes(self, *, key: str, data: bytes, content_type: str) -> None:
        _get_client().put_object(
            Bucket=settings.AWS_S3_BUCKET_NAME,
            Key=key,
            Body=data,
            ContentType=content_type,
            ServerSideEncryption="AES256",
        )
        log.info("[S3] uploaded %d bytes to %s", len(data), key)

    async def copy_object(self, *, src_key: str, dst_key: str) -> None:
        """Server-side copy (forwarding): the copy gets its own key and its own
        SSE, so deleting either message never strands the other."""
        bucket = settings.AWS_S3_BUCKET_NAME
        _get_client().copy_object(
            Bucket=bucket,
            Key=dst_key,
            CopySource={"Bucket": bucket, "Key": src_key},
            ServerSideEncryption="AES256",
        )
        log.info("[S3] copied %s -> %s", src_key, dst_key)

    async def delete_object(self, *, key: str) -> None:
        """Disposal (§164.310(d)(2)(i)): remove media for purged/deleted content."""
        _get_client().delete_object(Bucket=settings.AWS_S3_BUCKET_NAME, Key=key)
        log.info("[S3] deleted %s", key)

    async def presigned_url(self, *, key: str, expires_in: int = PRESIGNED_URL_TTL_SECONDS) -> str:
        url = _get_client().generate_presigned_url(
            "get_object",
            Params={"Bucket": settings.AWS_S3_BUCKET_NAME, "Key": key},
            ExpiresIn=expires_in,
        )
        return url

    # --- Presigned uploads (batch 5) ---------------------------------------- #
    # The client PUTs bytes straight to S3 (one PUT, or N multipart parts) so a
    # 100 MB video never passes through the API container. SSE is the bucket
    # default (see _ensure_bucket), so the presigned PUTs need no header.

    async def presigned_put(self, *, key: str, content_type: str, expires_in: int) -> str:
        return _get_client().generate_presigned_url(
            "put_object",
            Params={
                "Bucket": settings.AWS_S3_BUCKET_NAME,
                "Key": key,
                "ContentType": content_type,
            },
            ExpiresIn=expires_in,
        )

    async def create_multipart_upload(self, *, key: str, content_type: str) -> str:
        resp = _get_client().create_multipart_upload(
            Bucket=settings.AWS_S3_BUCKET_NAME,
            Key=key,
            ContentType=content_type,
            ServerSideEncryption="AES256",
        )
        return resp["UploadId"]

    async def presigned_upload_part(
        self, *, key: str, upload_id: str, part_number: int, expires_in: int
    ) -> str:
        return _get_client().generate_presigned_url(
            "upload_part",
            Params={
                "Bucket": settings.AWS_S3_BUCKET_NAME,
                "Key": key,
                "UploadId": upload_id,
                "PartNumber": part_number,
            },
            ExpiresIn=expires_in,
        )

    async def complete_multipart_upload(
        self, *, key: str, upload_id: str, parts: list[tuple[int, str]]
    ) -> None:
        _get_client().complete_multipart_upload(
            Bucket=settings.AWS_S3_BUCKET_NAME,
            Key=key,
            UploadId=upload_id,
            MultipartUpload={
                "Parts": [{"PartNumber": n, "ETag": etag} for n, etag in sorted(parts)]
            },
        )
        log.info("[S3] completed multipart %s (%d parts)", key, len(parts))

    async def abort_multipart_upload(self, *, key: str, upload_id: str) -> None:
        _get_client().abort_multipart_upload(
            Bucket=settings.AWS_S3_BUCKET_NAME, Key=key, UploadId=upload_id
        )
        log.info("[S3] aborted multipart %s", key)

    async def head_object(self, *, key: str) -> dict | None:
        """{size, content_type} or None when the object does not exist."""
        try:
            resp = _get_client().head_object(Bucket=settings.AWS_S3_BUCKET_NAME, Key=key)
        except ClientError as e:
            if str(e.response.get("Error", {}).get("Code", "")) in ("404", "NoSuchKey", "NotFound"):
                return None
            raise
        return {"size": int(resp["ContentLength"]), "content_type": resp.get("ContentType")}

    async def get_object(self, *, key: str) -> bytes:
        resp = _get_client().get_object(Bucket=settings.AWS_S3_BUCKET_NAME, Key=key)
        return resp["Body"].read()
