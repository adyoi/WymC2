"""File-type launcher icons for mobile agent builds.

Pure-stdlib rasterizer + PNG encoder so the server can produce Android
mipmap / iOS AppIcon assets without Pillow or any other dependency. Each
icon is a flat rounded square in the brand color of the disguised file type
(PDF / DOCX / XLSX / PPTX / ZIP / RAR) with the extension marker rendered
from a tiny embedded 5x7 bitmap font. Output is deterministic: the same
(kind, size) always yields the same bytes.
"""

import struct
import zlib

# ---------------------------------------------------------------------------
# 5x7 bitmap font — only the glyphs used by the markers below
# ---------------------------------------------------------------------------

_FONT = {
    "A": [".###.",
          "#...#",
          "#...#",
          "#####",
          "#...#",
          "#...#",
          "#...#"],
    "D": ["####.",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "####."],
    "F": ["#####",
          "#....",
          "#....",
          "####.",
          "#....",
          "#....",
          "#...."],
    "I": ["#####",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          "..#..",
          "#####"],
    "P": ["####.",
          "#...#",
          "#...#",
          "####.",
          "#....",
          "#....",
          "#...."],
    "R": ["####.",
          "#...#",
          "#...#",
          "####.",
          "#.#..",
          "#..#.",
          "#...#"],
    "W": ["#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "#.##.",
          "###.."],
    "X": ["#...#",
          "#...#",
          ".#.#.",
          "..#..",
          ".#.#.",
          "#...#",
          "#...#"],
    "Z": ["#####",
          "....#",
          "..#..",
          "..#..",
          ".#...",
          "#....",
          "#####"],
}

# kind -> (background RGB, marker text)
KIND_STYLES = {
    "pdf":  ((0xE8, 0x4B, 0x3A), "PDF"),
    "docx": ((0x2B, 0x6F, 0xC6), "W"),
    "xlsx": ((0x1E, 0x8C, 0x44), "X"),
    "pptx": ((0xD2, 0x55, 0x2B), "P"),
    "zip":  ((0xE0, 0xA4, 0x24), "ZIP"),
    "rar":  ((0x6E, 0x7D, 0x8A), "RAR"),
    "none": ((0x0F, 0x3A, 0x28), "WYM"),
}

ICON_KINDS = tuple(KIND_STYLES.keys())

_TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def _png_rgba(width: int, height: int, rgba: bytes) -> bytes:
    """Encode RGBA8 pixels as a PNG blob."""
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # filter type: None
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(typ: bytes, data: bytes) -> bytes:
        out = struct.pack(">I", len(data)) + typ + data
        out += struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)
        return out

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def _rounded_mask(size: int, radius: int) -> list[bool]:
    """Boolean mask of a rounded square inset by 7% of the canvas."""
    pad = max(1, int(size * 0.07))
    x0, x1 = pad, size - 1 - pad
    y0, y1 = pad, size - 1 - pad
    r = max(1, radius)
    mask: list[bool] = []
    for y in range(size):
        for x in range(size):
            if not (x0 <= x <= x1 and y0 <= y <= y1):
                mask.append(False)
                continue
            # distance from the nearest corner center
            cx = x0 + r if x < x0 + r else (x1 - r if x > x1 - r else x)
            cy = y0 + r if y < y0 + r else (y1 - r if y > y1 - r else y)
            dx, dy = x - cx, y - cy
            inside = (dx * dx + dy * dy <= r * r) if (x < x0 + r or x > x1 - r) and (y < y0 + r or y > y1 - r) else True
            mask.append(inside)
    return mask


def _rasterize(kind: str, size: int) -> bytes:
    bg, label = KIND_STYLES[kind]
    glyphs = [_FONT[c] for c in label if c in _FONT]
    if not glyphs:
        glyphs = [_FONT["I"]]
    rows = 7
    cols = sum(len(g[0]) for g in glyphs)
    scale = max(1, min((size * 86) // (100 * cols), (size * 52) // (100 * rows)))
    tw, th = cols * scale, rows * scale
    ox = (size - tw) // 2
    oy = (size - th) // 2

    mask = _rounded_mask(size, max(2, size // 16))
    ring = [False] * (size * size)
    # cheap 1px outline: any on-pixel with an off neighbour lies on the edge
    for y in range(1, size - 1):
        row = y * size
        for x in range(1, size - 1):
            i = row + x
            if mask[i] and not (mask[i - 1] and mask[i + 1]
                                and mask[i - size] and mask[i + size]):
                ring[i] = True

    fg = (242, 246, 244) if kind != "none" else (0x19, 0xCC, 0x78)
    ring_c = tuple(min(255, c + 45) for c in bg)

    px = bytearray(size * size * 4)
    glyph_x = ox
    for g in glyphs:
        for gy, grow in enumerate(g):
            for gx, ch in enumerate(grow):
                if ch != "#":
                    continue
                x0, y0 = glyph_x + gx * scale, oy + gy * scale
                for yy in range(y0, min(y0 + scale, size)):
                    base = yy * size * 4
                    for xx in range(max(x0, 0), min(x0 + scale, size)):
                        i = base + xx * 4
                        px[i], px[i + 1], px[i + 2] = fg
                        px[i + 3] = 255
        glyph_x += len(g[0]) * scale

    for i in range(size * size):
        if not mask[i]:
            continue
        o = i * 4
        if ring[i]:
            px[o], px[o + 1], px[o + 2] = ring_c
            px[o + 3] = 255
        elif px[o + 3] == 0:
            px[o], px[o + 1], px[o + 2] = bg
            px[o + 3] = 255
    return _png_rgba(size, size, bytes(px))


_RENDER_CACHE: dict[tuple[str, int], bytes] = {}


def render_file_icon(kind: str, size: int = 192) -> bytes:
    """PNG bytes of the file-type icon at ``size``px (square)."""
    kind = (kind or "none").lower()
    if kind not in KIND_STYLES:
        kind = "none"
    size = max(16, int(size))
    key = (kind, size)
    if key not in _RENDER_CACHE:
        _RENDER_CACHE[key] = _rasterize(kind, size)
    return _RENDER_CACHE[key]


def android_mipmaps(kind: str) -> dict[str, tuple[int, bytes]]:
    """{mipmap-dir: (px, png-bytes)} for res/ injection."""
    return {
        "mdpi": (48, render_file_icon(kind, 48)),
        "hdpi": (72, render_file_icon(kind, 72)),
        "xhdpi": (96, render_file_icon(kind, 96)),
        "xxhdpi": (144, render_file_icon(kind, 144)),
        "xxxhdpi": (192, render_file_icon(kind, 192)),
    }


def ios_appicons(kind: str) -> dict[str, tuple[int, bytes]]:
    """{AppIcon-<name>.png: (px, png-bytes)} for an AppIcon.appiconset."""
    out: dict[str, tuple[int, bytes]] = {}
    for name, px in (
        ("AppIcon-20@2x.png", 40), ("AppIcon-20@3x.png", 60),
        ("AppIcon-29@2x.png", 58), ("AppIcon-29@3x.png", 87),
        ("AppIcon-40@2x.png", 80), ("AppIcon-40@3x.png", 120),
        ("AppIcon-60@2x.png", 120), ("AppIcon-60@3x.png", 180),
        ("AppIcon-76@2x.png", 152), ("AppIcon-83.5@2x.png", 167),
        ("AppIcon-1024.png", 1024),
    ):
        out[name] = (px, render_file_icon(kind, px))
    return out