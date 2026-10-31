#!/usr/bin/env python3
"""Turns the worm renders into pixel art (same cel shading + 1 px outline as the miner) and
normal maps (tools/normal_maps.py):
  assets/sprites/worm_segment.png (+ _n): the 24, 18 and 12 px body segments side by side,
  assets/sprites/worm_head.png (+ _n): 16 directions x 2 mouth frames of 32 px cells,
  plus worm_segment.json and worm_head.json.
Run:  python3 tools/worm_sheet.py <render_dir>
"""
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_maps import FLAT, cel_mult, normal_map  # noqa: E402

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sprites")
os.makedirs(OUT, exist_ok=True)
OUTLINE = np.array([12, 9, 14, 255], dtype=np.uint8)
SIZES = (24, 18, 12)
CELL, DIRS, FRAMES = 32, 16, 2


def convert(name):
    flat = np.array(Image.open(f"{SRC}/{name}_flat.png").convert("RGBA")).astype(np.float32)
    clay = np.array(Image.open(f"{SRC}/{name}_clay.png").convert("RGB")).astype(np.float32) / 255
    solid = flat[..., 3] > 128
    rgb = flat[..., :3] * cel_mult(clay.mean(-1))[..., None]
    out = np.zeros(solid.shape + (4,), np.uint8)
    out[..., :3] = np.clip(rgb, 0, 255)
    out[..., 3] = np.where(solid, 255, 0)
    n = np.zeros_like(solid)
    n[1:] |= solid[:-1]; n[:-1] |= solid[1:]; n[:, 1:] |= solid[:, :-1]; n[:, :-1] |= solid[:, 1:]
    out[n & ~solid] = OUTLINE
    return out, normal_map(f"{SRC}/{name}_normal.png", out)


def blank(h, w):
    a = np.zeros((h, w, 4), np.uint8)
    b = a.copy()
    b[..., :3] = FLAT
    return a, b


# body segments: one strip, each segment centred vertically in a 24 px tall row
strip, strip_n = blank(max(SIZES), sum(SIZES))
rects, x = [], 0
for s in SIZES:
    y = (max(SIZES) - s) // 2
    strip[y:y + s, x:x + s], strip_n[y:y + s, x:x + s] = convert(f"segment_{s}")
    rects.append([x, y, s, s])
    x += s
Image.fromarray(strip, "RGBA").save(f"{OUT}/worm_segment.png")
Image.fromarray(strip_n, "RGBA").save(f"{OUT}/worm_segment_n.png")
json.dump({"sizes": list(SIZES), "rects": rects, "note": "rects are [x, y, w, h] in worm_segment.png"},
          open(f"{OUT}/worm_segment.json", "w"), indent=1)

# head: columns = 16 travel directions (0 = right, 22.5 degrees clockwise each), rows = mouth frames
grid, grid_n = blank(CELL * FRAMES, CELL * DIRS)
for f in range(FRAMES):
    for d in range(DIRS):
        cell = np.s_[f * CELL:(f + 1) * CELL, d * CELL:(d + 1) * CELL]
        grid[cell], grid_n[cell] = convert(f"head_{f}_{d}")
Image.fromarray(grid, "RGBA").save(f"{OUT}/worm_head.png")
Image.fromarray(grid_n, "RGBA").save(f"{OUT}/worm_head_n.png")
json.dump({"dirs": DIRS, "frames": FRAMES, "cell": CELL,
           "note": "column = direction (0 = moving right, +22.5 deg clockwise, y down), "
                   "row = mouth (0 closed, 1 open); the head's centre is the cell centre"},
          open(f"{OUT}/worm_head.json", "w"), indent=1)
print("wrote worm_segment", strip.shape[1::-1], "worm_head", grid.shape[1::-1])
