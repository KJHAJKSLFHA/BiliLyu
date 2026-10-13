#!/usr/bin/env python3
"""Generate the BiliLyu app icon (.icns) — B站 blue→pink gradient, white play glyph."""

import os
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024          # final icon canvas
SS = 4                 # supersample factor
W = CANVAS * SS

# macOS Big Sur+ icon geometry: content occupies ~82% of the canvas.
CONTENT = int(W * 0.82)
OFFSET = (W - CONTENT) // 2
RADIUS = int(CONTENT * 0.2237)

GRAD_A = (0x00, 0xA1, 0xD6)   # Bilibili blue
GRAD_B = (0xFB, 0x72, 0x99)   # Bilibili pink


def diagonal_gradient(size: int, a, b) -> Image.Image:
    small = 256
    img = Image.new("RGB", (small, small))
    px = img.load()
    for y in range(small):
        for x in range(small):
            t = (x + y) / (2 * (small - 1))
            px[x, y] = tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))
    return img.resize((size, size), Image.BICUBIC)


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def rounded_polygon_mask(size: int, pts, radius: float) -> Image.Image:
    """Convex polygon with uniformly rounded corners.

    Drawing the polygon then blurring and re-thresholding the mask rounds every
    corner by roughly `radius`, without the lumps you get from stamping circles
    on the vertices.
    """
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius))
    return mask.point(lambda v: 255 if v > 128 else 0)


def play_mask(size: int) -> Image.Image:
    cx, cy = size / 2, size / 2
    w, h = size * 0.30, size * 0.36
    cx += w * 0.06  # optical centring
    pts = [
        (cx - w / 2, cy - h / 2),
        (cx + w / 2, cy),
        (cx - w / 2, cy + h / 2),
    ]
    return rounded_polygon_mask(size, pts, size * 0.018)


def top_glow(size: int) -> Image.Image:
    """Soft white-to-transparent vertical wash for a little depth."""
    ramp = Image.new("L", (1, size), 0)
    px = ramp.load()
    for y in range(size):
        t = y / (size - 1)
        px[0, y] = max(0, int(34 * (1 - t / 0.55))) if t < 0.55 else 0
    ramp = ramp.resize((size, size), Image.BICUBIC)
    glow = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    glow.putalpha(ramp)
    return glow


def build_master() -> Image.Image:
    icon = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    # Rounded card with the brand gradient and a soft top highlight.
    grad = diagonal_gradient(CONTENT, GRAD_A, GRAD_B).convert("RGBA")
    card = Image.new("RGBA", (CONTENT, CONTENT), (0, 0, 0, 0))
    card.paste(grad, (0, 0))
    card = Image.alpha_composite(card, top_glow(CONTENT))

    mask = rounded_mask(CONTENT, RADIUS)
    card.putalpha(mask)

    # White play glyph.
    glyph = Image.new("RGBA", (CONTENT, CONTENT), (255, 255, 255, 255))
    card = Image.composite(glyph, card, play_mask(CONTENT))

    icon.paste(card, (OFFSET, OFFSET), card)
    return icon.resize((CANVAS, CANVAS), Image.LANCZOS)


def write_icns(master: Image.Image, path: str) -> None:
    """Write a PNG-based .icns container.

    `iconutil` is unreliable here, and the format is simple enough to emit
    directly: an 'icns' header followed by typed, length-prefixed PNG chunks.
    """
    import io
    import struct

    # (chunk type, pixel size)
    chunks = [
        (b"icp4", 16), (b"icp5", 32), (b"icp6", 64),
        (b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
        (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
    ]

    body = bytearray()
    for tag, px in chunks:
        buf = io.BytesIO()
        master.resize((px, px), Image.LANCZOS).save(buf, "PNG")
        data = buf.getvalue()
        body += tag + struct.pack(">I", len(data) + 8) + data

    with open(path, "wb") as fh:
        fh.write(b"icns" + struct.pack(">I", len(body) + 8) + bytes(body))


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)

    master = build_master()
    master.save(os.path.join(out_dir, "AppIcon-1024.png"), "PNG")

    icns = os.path.join(out_dir, "AppIcon.icns")
    write_icns(master, icns)
    print(f"icon written: {icns} ({os.path.getsize(icns)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
