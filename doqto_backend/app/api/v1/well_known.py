"""Universal links (iOS) and App Links (Android), batch 7. Unauthenticated,
static, served at the root so https://doqto.ai/.well-known/... can be
proxied straight to the API. No user data."""
from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import JSONResponse

from app.core.constants import (
    ANDROID_CERT_SHA256_FINGERPRINTS,
    ANDROID_PACKAGE_NAME,
    APPLE_APP_BUNDLE_ID,
    APPLE_TEAM_ID,
    UNIVERSAL_LINK_PATHS,
)
from app.core.routes import ApiRoutes

router = APIRouter()

_CACHE = {"Cache-Control": "public, max-age=3600"}


def aasa_payload() -> dict:
    app_id = f"{APPLE_TEAM_ID}.{APPLE_APP_BUNDLE_ID}"
    return {
        "applinks": {
            "details": [
                {
                    "appIDs": [app_id],
                    "components": [{"/": path} for path in UNIVERSAL_LINK_PATHS],
                }
            ]
        },
        "webcredentials": {"apps": [app_id]},
    }


def assetlinks_payload() -> list[dict]:
    return [
        {
            "relation": ["delegate_permission/common.handle_all_urls"],
            "target": {
                "namespace": "android_app",
                "package_name": ANDROID_PACKAGE_NAME,
                "sha256_cert_fingerprints": list(ANDROID_CERT_SHA256_FINGERPRINTS),
            },
        }
    ]


@router.get(ApiRoutes.WELL_KNOWN_AASA, include_in_schema=False)
async def apple_app_site_association() -> JSONResponse:
    # Apple requires application/json with no extension — never redirect.
    return JSONResponse(aasa_payload(), media_type="application/json", headers=_CACHE)


@router.get(ApiRoutes.WELL_KNOWN_ASSETLINKS, include_in_schema=False)
async def assetlinks() -> JSONResponse:
    """Placeholder until the Play App Signing SHA-256 fingerprints are in
    ANDROID_CERT_SHA256_FINGERPRINTS — Android ignores an empty list."""
    return JSONResponse(assetlinks_payload(), media_type="application/json", headers=_CACHE)
