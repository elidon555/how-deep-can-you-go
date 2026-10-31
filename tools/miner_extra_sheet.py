#!/usr/bin/env python3
"""Appends the crew-rescue rows (down, carried, carry, throw) rendered by
tools/miner_extra_blender.py to assets/sprites/miner.png, miner_n.png and miner.json.

Every existing row is copied over untouched (pixel-identical); the new rows go below them with
the same 80 px cell, 12 columns, stepped shading, 1 px outline and normal map as
tools/miner_sheet.py. Re-running replaces these four rows instead of appending them again.
NOTE: tools/miner_sheet.py rewrites the sheet from scratch with only its own rows, so run this
again after it.
Run:  python3 tools/miner_extra_sheet.py <render_dir>
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
CELL = 80
EXTRA = [("down", 4), ("carried", 4), ("carry", 12), ("throw", 6)]
OUTLINE = np.array([12, 9, 14, 255], dtype=np.uint8)
UNLIT = [np.array(c) for c in ([255, 246, 192], [255, 179, 71])]   # headlamp, pack lantern


def frame(name, i):
    """Same as tools/miner_sheet.py's frame()."""
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
    s = solid
    n = np.zeros_like(s)
    n[1:] |= s[:-1]; n[:-1] |= s[1:]; n[:, 1:] |= s[:, :-1]; n[:, :-1] |= s[:, 1:]
    out[n & ~s] = OUTLINE
    return out, normal_map(f"{SRC}/{name}_{i}_normal.png", out)


meta = json.load(open(os.path.join(OUT, "miner.json")))
old = np.array(Image.open(os.path.join(OUT, "miner.png")).convert("RGBA"))
old_n = np.array(Image.open(os.path.join(OUT, "miner_n.png")).convert("RGBA"))
cols = meta["columns"]
extra_names = {n for n, _ in EXTRA}
base = {k: v for k, v in meta["anims"].items() if k not in extra_names}
base_rows = max(v["row"] for v in base.values()) + 1
assert old.shape[1] == cols * CELL and old.shape[0] >= base_rows * CELL

rows = base_rows + len(EXTRA)
sheet = np.zeros((rows * CELL, cols * CELL, 4), np.uint8)
normals = np.zeros_like(sheet)
normals[..., :3] = FLAT
sheet[:base_rows * CELL] = old[:base_rows * CELL]
normals[:base_rows * CELL] = old_n[:base_rows * CELL]
anims = dict(base)
for k, (name, count) in enumerate(EXTRA):
    row = base_rows + k
    anims[name] = {"row": row, "frames": count}
    for i in range(count):
        cell = np.s_[row * CELL:(row + 1) * CELL, i * CELL:(i + 1) * CELL]
        sheet[cell], normals[cell] = frame(name, i)
Image.fromarray(sheet, "RGBA").save(os.path.join(OUT, "miner.png"))
Image.fromarray(normals, "RGBA").save(os.path.join(OUT, "miner_n.png"))
meta["anims"] = anims
json.dump(meta, open(os.path.join(OUT, "miner.json"), "w"), indent=1)
print("appended", [n for n, _ in EXTRA], "->", sheet.shape[1::-1])
