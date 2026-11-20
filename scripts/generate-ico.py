#!/usr/bin/env python3
"""Builds assets/AppIcon.ico (Windows) from the existing app icon asset assets/AppIcon.icns.

Nothing is drawn here: every frame is an existing rendering from the .icns (the Mac build renders each size natively,
see scripts/generate-icns.sh), scaled down only for sizes the .icns has no rendering for (20/24/40/48).
Usage: python3 scripts/generate-ico.py [out.ico]   (needs Pillow)
"""
import io
import struct
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ICNS = ROOT / "assets" / "AppIcon.icns"
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]


def natives(icns: Path) -> dict[int, Image.Image]:
    """size -> the .icns's own 1x rendering of that pixel size (a @2x rendering of half the size also counts)."""
    out: dict[int, Image.Image] = {}
    with Image.open(icns) as icon:
        for entry in sorted(icon.info.get("sizes", [])):
            w, h, scale = entry
            icon.size = (w, h)
            icon.load(scale)
            out.setdefault(w * scale, icon.convert("RGBA").copy())
    return out


def frame(size: int, native: dict[int, Image.Image]) -> bytes:
    if size in native:
        image = native[size]
    else:
        bigger = min(s for s in native if s > size)
        image = native[bigger].resize((size, size), Image.LANCZOS)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "assets" / "AppIcon.ico"
    native = natives(ICNS)
    frames = [(s, frame(s, native)) for s in SIZES]
    header = struct.pack("<HHH", 0, 1, len(frames))
    offset = 6 + 16 * len(frames)
    directory, data = b"", b""
    for size, png in frames:
        directory += struct.pack("<BBBBHHII", 0 if size >= 256 else size, 0 if size >= 256 else size, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    out.write_bytes(header + directory + data)
    print(f"{out}: {len(frames)} frames {SIZES}, {out.stat().st_size} bytes; icns natives {sorted(native)}")


if __name__ == "__main__":
    main()
