#!/usr/bin/env python3
"""Generates the app icon (1024x1024 RGB PNG, no alpha) without external dependencies."""
import math
import pathlib
import struct
import zlib

SIZE = 1024
OUT = pathlib.Path(__file__).resolve().parent.parent / "Networker" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"


def lerp(a, b, t):
    return a + (b - a) * t


def dist_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length_sq = dx * dx + dy * dy
    t = 0.0 if length_sq == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length_sq))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy)


def main():
    center = SIZE / 2
    nodes = [(center + 300 * math.cos(a), center + 300 * math.sin(a))
             for a in (math.radians(d) for d in (-90, -18, 54, 126, 198))]
    rows = []
    for y in range(SIZE):
        t = y / (SIZE - 1)
        bg = (int(lerp(18, 40, t)), int(lerp(52, 110, t)), int(lerp(120, 220, t)))
        row = bytearray([0])  # PNG filter type 0
        for x in range(SIZE):
            px, py = x + 0.5, y + 0.5
            coverage = 0.0
            # Spokes from the centre to each node.
            for nx, ny in nodes:
                d = dist_to_segment(px, py, center, center, nx, ny)
                coverage = max(coverage, min(1.0, max(0.0, 14 - d)))
            # Outer ring.
            ring = abs(math.hypot(px - center, py - center) - 300)
            coverage = max(coverage, min(1.0, max(0.0, 16 - ring)))
            # Nodes and hub.
            for nx, ny in nodes:
                coverage = max(coverage, min(1.0, max(0.0, 52 - math.hypot(px - nx, py - ny))))
            coverage = max(coverage, min(1.0, max(0.0, 78 - math.hypot(px - center, py - center))))
            r = int(lerp(bg[0], 255, coverage))
            g = int(lerp(bg[1], 255, coverage))
            b = int(lerp(bg[2], 255, coverage))
            row += bytes((r, g, b))
        rows.append(bytes(row))

    raw = b"".join(rows)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    OUT.write_bytes(png)
    print(f"wrote {OUT} ({len(png)} bytes)")


if __name__ == "__main__":
    main()
