"""Reporting a user from their profile (App Store Guideline 1.2)."""
from __future__ import annotations

from sqlalchemy import select

from app.models import Report
from tests import helpers

REPORTS = "/api/v1/network/reports"


async def test_app_report_body_files_a_user_report(client, db):
    # Exactly what the app sends from a profile's ⋯ → Report: no subject_type.
    me = await helpers.create_user(db)
    them = await helpers.create_user(db)
    me_id, them_id = me.id, them.id
    r = await client.post(
        REPORTS, json={"subject_id": str(them_id), "reason": "other"},
        headers=await helpers.auth_headers(me_id),
    )
    assert r.status_code == 201, r.text
    rep = (await db.scalars(select(Report))).one()
    assert (rep.reporter_id, rep.subject_type, rep.subject_id) == (me_id, "user", them_id)
