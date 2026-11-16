"""Generate the bundled notification tones (batch 6).

Each tone is a short synthesised chime: a few sine partials with an
exponential decay, 16 kHz mono 16-bit PCM, under 30 KB. Writes

    assets/tones/<name>.wav                       (in-app preview)
    android/app/src/main/res/raw/<name>.wav       (FCM channel / sound)
    ios/Runner/Resources/tones/<name>.caf         (APNs aps.sound, via afconvert)

Names mirror NOTIFICATION_TONES in doqto_backend/app/core/constants.py.
Run from doqto_app/:  python3 tool/gen_tones.py
"""
from __future__ import annotations

import math
import shutil
import struct
import subprocess
import wave
from pathlib import Path

RATE = 16000
APP = Path(__file__).resolve().parents[1]

# name -> (duration s, [(freq, amplitude, decay/s, start s)])
TONES: dict[str, tuple[float, list[tuple[float, float, float, float]]]] = {
    "chime": (0.80, [(880, 0.5, 4, 0), (1320, 0.3, 5, 0.08), (1760, 0.2, 6, 0.16)]),
    "pulse": (0.70, [(660, 0.6, 9, 0), (660, 0.6, 9, 0.22), (660, 0.5, 9, 0.44)]),
    "ping": (0.60, [(1568, 0.55, 7, 0), (3136, 0.15, 10, 0)]),
    "bell": (0.80, [(523, 0.5, 3, 0), (1046, 0.25, 4, 0), (1570, 0.15, 6, 0), (2093, 0.08, 8, 0)]),
    "glass": (0.75, [(2093, 0.4, 5, 0), (2637, 0.3, 6, 0.05), (3136, 0.2, 7, 0.1)]),
    "note": (0.65, [(784, 0.55, 5, 0), (1568, 0.2, 7, 0)]),
    "pop": (0.40, [(392, 0.7, 18, 0), (784, 0.3, 20, 0)]),
    "ripple": (0.80, [(1046, 0.4, 6, 0), (1174, 0.35, 6, 0.12), (1318, 0.3, 6, 0.24), (1568, 0.25, 6, 0.36)]),
    "signal": (0.70, [(1200, 0.5, 12, 0), (1200, 0.5, 12, 0.18), (1600, 0.5, 10, 0.36)]),
    "tap": (0.35, [(1000, 0.6, 25, 0), (2000, 0.2, 30, 0)]),
    "whistle": (0.80, [(1760, 0.45, 4, 0), (2217, 0.35, 5, 0.1), (2637, 0.25, 6, 0.2)]),
}


def render(duration: float, partials) -> bytes:
    n = int(RATE * duration)
    out = bytearray()
    for i in range(n):
        t = i / RATE
        v = 0.0
        for freq, amp, decay, start in partials:
            if t < start:
                continue
            dt = t - start
            # 5 ms attack so the onset never clicks.
            env = min(1.0, dt / 0.005) * math.exp(-decay * dt)
            v += amp * env * math.sin(2 * math.pi * freq * dt)
        # Fade the tail so the file ends at silence.
        if n - i < RATE * 0.02:
            v *= (n - i) / (RATE * 0.02)
        out += struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767 * 0.8))
    return bytes(out)


def write_wav(path: Path, pcm: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)


def main() -> None:
    assets = APP / "assets" / "tones"
    raw = APP / "android" / "app" / "src" / "main" / "res" / "raw"
    caf_dir = APP / "ios" / "Runner" / "Resources" / "tones"
    caf_dir.mkdir(parents=True, exist_ok=True)
    raw.mkdir(parents=True, exist_ok=True)
    afconvert = shutil.which("afconvert")
    for name, (dur, partials) in TONES.items():
        pcm = render(dur, partials)
        wav = assets / f"{name}.wav"
        write_wav(wav, pcm)
        shutil.copyfile(wav, raw / f"{name}.wav")
        caf = caf_dir / f"{name}.caf"
        if afconvert:
            subprocess.run([afconvert, "-f", "caff", "-d", "LEI16", str(wav), str(caf)], check=True)
        sizes = [p.stat().st_size for p in (wav, caf) if p.exists()]
        assert all(s < 30 * 1024 for s in sizes), (name, sizes)
        print(f"{name:8s} {dur:.2f}s  wav {wav.stat().st_size:6d} B  caf {caf.stat().st_size if caf.exists() else 0:6d} B")


if __name__ == "__main__":
    main()
