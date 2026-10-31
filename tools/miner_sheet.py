#!/usr/bin/env python3
"""Turns the Blender renders (flat + clay) into the pixel-art sprite sheet.

Stepped (cel) shading from the clay pass, 1 px dark outline, unshaded lamp.
Writes assets/sprites/miner.png (8 columns x 10 rows of 80x80) + miner.json.
Run:  python3 tools/miner_sheet.py <render_dir>
"""
import json
import os
import sys

import numpy as np
from PIL import Image

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sprites")
os.makedirs(OUT, exist_ok=True)
CELL = 80
ORDER = [("idle", 4), ("run", 8), ("jump", 2), ("fall", 2), ("dig_side", 8), ("dig_down", 8), ("dig_up", 8),
         ("land", 2), ("climb", 4), ("hurt", 2)]
ROPE_X = 0.30      # climb rope x in miner_blender.py (world units right of the cell centre)
OUTLINE = np.array([12, 9, 14, 255], dtype=np.uint8)
LAMP = np.array([255, 246, 192])


def frame(name, i):
    flat = np.array(Image.open(f"{SRC}/{name}_{i}_flat.png").convert("RGBA")).astype(np.float32)
    clay = np.array(Image.open(f"{SRC}/{name}_{i}_clay.png").convert("RGB")).astype(np.float32) / 255
    solid = flat[..., 3] > 128
    lum = clay.mean(axis=-1)
    # 4 tone bands: shadow, mid, lit, highlight
    mult = np.select([lum > 0.78, lum > 0.5, lum > 0.27], [1.12, 0.92, 0.72], 0.52)
    rgb = flat[..., :3] * mult[..., None]
    lamp = np.abs(flat[..., :3] - LAMP).sum(-1) < 40
    rgb[lamp] = LAMP
    out = np.zeros((CELL, CELL, 4), dtype=np.uint8)
    out[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    out[..., 3] = np.where(solid, 255, 0)
    # outline: empty pixels touching the silhouette
    s = solid
    n = np.zeros_like(s)
    n[1:] |= s[:-1]; n[:-1] |= s[1:]; n[:, 1:] |= s[:, :-1]; n[:, :-1] |= s[:, 1:]
    out[n & ~s] = OUTLINE
    return out


sheet = np.zeros((CELL * len(ORDER), CELL * 8, 4), dtype=np.uint8)
anims = {}
for row, (name, count) in enumerate(ORDER):
    anims[name] = {"row": row, "frames": count}
    for i in range(count):
        sheet[row * CELL:(row + 1) * CELL, i * CELL:(i + 1) * CELL] = frame(name, i)
Image.fromarray(sheet, "RGBA").save(os.path.join(OUT, "miner.png"))
# feet sit at z=0, camera centre at z=1.2, ortho 3.625 -> px below the cell centre
meta = {"cell": CELL, "columns": 8, "anims": anims, "feet_below_center": round(1.2 / 3.625 * CELL, 1),
        "climb_rope_x": round(ROPE_X / 3.625 * CELL, 1)}   # px right of the cell centre
json.dump(meta, open(os.path.join(OUT, "miner.json"), "w"), indent=1)
print("wrote miner.png", sheet.shape, meta["feet_below_center"])
