#!/usr/bin/env python3
"""Turns the Blender renders (flat + clay + normal) into the miner's pixel-art sprite sheet.

Stepped (cel) shading from the clay pass, 1 px dark outline, unshaded headlamp and lantern.
Writes assets/sprites/miner.png + miner_n.png (normal map, same layout; see
tools/normal_maps.py), COLUMNS columns x 12 rows of 80x80, and miner.json.
Run:  python3 tools/miner_sheet.py <render_dir>
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
CELL = 80
COLUMNS = 12
# the game times pickaxe hits on frame 5 of each dig row: those stay at 8 frames
ORDER = [("idle", 8), ("run", 12), ("jump", 3), ("fall", 3), ("dig_side", 8), ("dig_down", 8), ("dig_up", 8),
         ("land", 3), ("climb", 6), ("hurt", 3), ("roll", 6), ("swim", 6)]
ROPE_X = 0.30      # climb rope x in miner_blender.py (world units right of the cell centre)
OUTLINE = np.array([12, 9, 14, 255], dtype=np.uint8)
UNLIT = [np.array(c) for c in ([255, 246, 192], [255, 179, 71])]   # headlamp, pack lantern


def frame(name, i):
    flat = np.array(Image.open(f"{SRC}/{name}_{i}_flat.png").convert("RGBA")).astype(np.float32)
    clay = np.array(Image.open(f"{SRC}/{name}_{i}_clay.png").convert("RGB")).astype(np.float32) / 255
    solid = flat[..., 3] > 128
    rgb = flat[..., :3] * cel_mult(clay.mean(axis=-1))[..., None]
    for key in UNLIT:
        lit = np.abs(flat[..., :3] - key).sum(-1) < 40
        rgb[lit] = key
    out = np.zeros((CELL, CELL, 4), dtype=np.uint8)
    out[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    out[..., 3] = np.where(solid, 255, 0)
    # outline: empty pixels touching the silhouette
    s = solid
    n = np.zeros_like(s)
    n[1:] |= s[:-1]; n[:-1] |= s[1:]; n[:, 1:] |= s[:, :-1]; n[:, :-1] |= s[:, 1:]
    out[n & ~s] = OUTLINE
    return out, normal_map(f"{SRC}/{name}_{i}_normal.png", out)


sheet = np.zeros((CELL * len(ORDER), CELL * COLUMNS, 4), dtype=np.uint8)
normals = np.zeros_like(sheet)
normals[..., :3] = FLAT          # empty cells: flat, transparent
anims = {}
for row, (name, count) in enumerate(ORDER):
    anims[name] = {"row": row, "frames": count}
    for i in range(count):
        cell = np.s_[row * CELL:(row + 1) * CELL, i * CELL:(i + 1) * CELL]
        sheet[cell], normals[cell] = frame(name, i)
Image.fromarray(sheet, "RGBA").save(os.path.join(OUT, "miner.png"))
Image.fromarray(normals, "RGBA").save(os.path.join(OUT, "miner_n.png"))
# feet sit at z=0, camera centre at z=1.2, ortho 3.625 -> px below the cell centre
meta = {"cell": CELL, "columns": COLUMNS, "anims": anims, "feet_below_center": round(1.2 / 3.625 * CELL, 1),
        "climb_rope_x": round(ROPE_X / 3.625 * CELL, 1)}   # px right of the cell centre
json.dump(meta, open(os.path.join(OUT, "miner.json"), "w"), indent=1)
print("wrote miner.png + miner_n.png", sheet.shape, meta["feet_below_center"])
