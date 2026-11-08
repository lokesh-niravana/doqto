"""App metadata (batch 6) — unauthenticated, cacheable, no user data.

`min-version` drives the force-update screen; `legal` hands the app its help /
terms / privacy / HIPAA links so a URL change never needs a release.
"""
from __future__ import annotations

from fastapi import APIRouter

from app.core.config import settings
from app.core.constants import LEGAL_URLS
from app.core.routes import ApiRoutes
from app.schemas.settings import LegalOut, MinVersionOut

router = APIRouter()


@router.get(ApiRoutes.APP_MIN_VERSION, response_model=MinVersionOut)
async def min_version() -> MinVersionOut:
    """Lowest `version+build` allowed per platform. The app compares its own
    build number (after the `+`) and blocks when below."""
    return MinVersionOut(
        ios=settings.MIN_VERSION_IOS,
        android=settings.MIN_VERSION_ANDROID,
        message=settings.MIN_VERSION_MESSAGE,
    )


@router.get(ApiRoutes.APP_LEGAL, response_model=LegalOut)
async def legal() -> LegalOut:
    return LegalOut(**LEGAL_URLS)
