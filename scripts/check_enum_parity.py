#!/usr/bin/env python3
"""CI gate — enforces enum wire-value parity across three sources of truth:
  1. docs/enums.md                                   (human-readable contract)
  2. doqto_backend/app/core/enums.py               (Python StrEnum)
  3. doqto_app/lib/core/enums/app_enums.dart       (Dart enum .wire)

Fails with non-zero exit code if any set differs. Parses text — no Python/Dart
toolchain required.

Usage:
    python3 scripts/check_enum_parity.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs" / "enums.md"
PY = ROOT / "doqto_backend" / "app" / "core" / "enums.py"
DART = ROOT / "doqto_app" / "lib" / "core" / "enums" / "app_enums.dart"

# Enum names that appear in all three sources and must match.
SHARED = {
    "UserRole",
    "OrgStatus",
    "OrgRole",
    "PracticeType",
    "ConversationType",
    # ConversationAccess reaches the client wire from M3 (ConversationOut.access)
    # so it is gated. ExternalDmPolicy / DirectoryVisibility are backend-only
    # org-admin policy enums — deliberately NOT gated, no Dart mirror needed.
    "ConversationAccess",
    # Networking graph (M1). InvitationStatus + the three privacy-setting enums
    # reach the client wire (invitation lists, PATCH /users/me/privacy) so they
    # are gated. ReportStatus is backend-only (moderation) — deliberately NOT
    # gated, like ExternalDmPolicy / DirectoryVisibility. NOTE: backend M1 ships
    # one release ahead of the client, so these will read as "dart-missing"
    # drift until the client agent mirrors them in its M1 — expected.
    "InvitationStatus",
    "InvitePolicy",
    "DmPolicy",
    "Discoverability",
    # Privacy screen (batch 2): all three reach the client wire via
    # GET/PATCH /users/me/privacy.
    "LastSeenVisibility",
    "OnlineVisibility",
    "ProfileFieldVisibility",
    # Groups (M5). Only GroupRole reaches the client wire (role pills), so it
    # alone is gated. The rest (post/member-DM policy, member/invite states) are
    # backend-only — deliberately NOT gated, no Dart mirror needed. Visibility
    # and join policy were retired when groups became invite-only.
    "GroupRole",
    # Batch 4: the report-reason picker renders from this enum. ReportSubjectType
    # and ReportStatus stay backend-only.
    "ReportReason",
    "MessageType",
    "TranscriptStatus",
    "WsEventServer",
    "WsEventClient",
    # Settings (batch 6): the status picker and the vibrate picker render from
    # these. The notification tone list is a plain string (resource name).
    "StatusPreset",
    "VibratePattern",
}


def parse_docs(path: Path) -> dict[str, set[str]]:
    """Parse ## <EnumName> sections with tables of wire values (first column)."""
    text = path.read_text()
    out: dict[str, set[str]] = {}
    current: str | None = None
    for line in text.splitlines():
        m = re.match(r"^##\s+([A-Za-z]+)\b", line)
        if m:
            name = m.group(1)
            current = name if name in SHARED else None
            if current:
                out[current] = set()
            continue
        if current is None:
            continue
        # Table row: | `value` | meaning |
        m = re.match(r"^\|\s*`([a-zA-Z_0-9]+)`\s*\|", line)
        if m:
            out[current].add(m.group(1))
    return out


def parse_python(path: Path) -> dict[str, set[str]]:
    text = path.read_text()
    out: dict[str, set[str]] = {}
    # class Foo(StrEnum):
    #     NAME = "wire"
    blocks = re.finditer(
        r"^class\s+(\w+)\(StrEnum\):\s*\n((?:[ \t]+.*\n?)+)", text, flags=re.MULTILINE
    )
    for m in blocks:
        name = m.group(1)
        if name not in SHARED:
            continue
        body = m.group(2)
        values = set(re.findall(r'=\s*"([^"]+)"', body))
        out[name] = values
    return out


def parse_dart(path: Path) -> dict[str, set[str]]:
    """Dart enum blocks can contain getter bodies with nested braces, so we
    walk the text and match braces manually from each `enum Name {` token."""
    text = path.read_text()
    out: dict[str, set[str]] = {}

    for em in re.finditer(r"\benum\s+(\w+)\s*\{", text):
        name = em.group(1)
        if name not in SHARED:
            continue
        start = em.end() - 1  # position of opening '{'
        depth = 0
        end = start
        for i in range(start, len(text)):
            ch = text[i]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        body = text[start + 1 : end]
        sw = re.search(r"String\s+get\s+wire\s*=>\s*switch\s*\(this\)\s*\{", body)
        if not sw:
            out[name] = set()
            continue
        # Match braces for the switch body.
        sdepth = 0
        sstart = sw.end() - 1
        send = sstart
        for i in range(sstart, len(body)):
            ch = body[i]
            if ch == "{":
                sdepth += 1
            elif ch == "}":
                sdepth -= 1
                if sdepth == 0:
                    send = i
                    break
        switch_body = body[sstart + 1 : send]
        arms = re.findall(r"=>\s*'([^']+)'", switch_body)
        # A5 enum tolerance: Dart enums carry a client-only `unknown` sentinel
        # that fromWire falls back to for unrecognized wire values. The server
        # never emits 'unknown', so it is not part of the wire contract and is
        # excluded from the parity comparison.
        out[name] = set(arms) - {"unknown"}
    return out


def main() -> int:
    for p in (DOCS, PY, DART):
        if not p.exists():
            print(f"ERROR: missing {p}", file=sys.stderr)
            return 2

    docs = parse_docs(DOCS)
    py = parse_python(PY)
    dart = parse_dart(DART)

    failed = False
    for name in sorted(SHARED):
        d = docs.get(name, set())
        p = py.get(name, set())
        t = dart.get(name, set())
        if not (d == p == t):
            failed = True
            print(f"✗ {name} — drift detected")
            print(f"  docs:   {sorted(d)}")
            print(f"  python: {sorted(p)}")
            print(f"  dart:   {sorted(t)}")
            if d - p:
                print(f"  in docs only: {sorted(d - p)}")
            if p - d:
                print(f"  in python only: {sorted(p - d)}")
            if t - d:
                print(f"  in dart only: {sorted(t - d)}")
            print()
        else:
            print(f"✓ {name}: {sorted(d)}")

    if failed:
        print("\nEnum parity check FAILED.", file=sys.stderr)
        return 1
    print("\nAll enums in sync.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
