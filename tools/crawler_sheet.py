#!/usr/bin/env python3
"""Turns the crawler renders (flat + clay) into its pixel-art sprite sheet + eye glow sheet.

Same stepped shading and 1 px outline as the miner. The glowing eyes stay unshaded and are
also written alone to crawler_glow.png (same layout) for a bloom layer.
Writes assets/sprites/crawler.png, crawler_glow.png (8 columns x 4 rows of 64x48) + crawler.json.
Run:  python3 tools/crawler_sheet.py <render_dir>
"""
import json
import os
import sys

import numpy as np
from PIL import Image

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sprites")
os.makedirs(OUT, exist_ok=True)
CELL_W, CELL_H = 64, 48
FEET_BELOW_CENTER = 20        # as in crawler_blender.py
ORDER = [("walk", 6), ("lunge", 4), ("hurt", 2), ("die", 3)]
OUTLINE = np.array([12, 9, 14, 255], dtype=np.uint8)
EYE = np.array([255, 90, 30])


def frame(name, i):
    flat = np.array(Image.open(f"{SRC}/{name}_{i}_flat.png").convert("RGBA")).astype(np.float32)
    clay = np.array(Image.open(f"{SRC}/{name}_{i}_clay.png").convert("RGB")).astype(np.float32) / 255
    solid = flat[..., 3] > 128
    lum = clay.mean(axis=-1)
    # 4 tone bands: shadow, mid, lit, highlight
    mult = np.select([lum > 0.78, lum > 0.5, lum > 0.27], [1.12, 0.92, 0.72], 0.52)
    rgb = flat[..., :3] * mult[..., None]
    eye = (np.abs(flat[..., :3] - EYE).sum(-1) < 60) & solid
    rgb[eye] = EYE
    out = np.zeros((CELL_H, CELL_W, 4), dtype=np.uint8)
    out[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    out[..., 3] = np.where(solid, 255, 0)
    # outline: empty pixels touching the silhouette
    s = solid
    n = np.zeros_like(s)
    n[1:] |= s[:-1]; n[:-1] |= s[1:]; n[:, 1:] |= s[:, :-1]; n[:, :-1] |= s[:, 1:]
    out[n & ~s] = OUTLINE
    glow = np.zeros_like(out)
    glow[eye, :3] = EYE
    glow[eye, 3] = 255
    return out, glow


sheet = np.zeros((CELL_H * len(ORDER), CELL_W * 8, 4), dtype=np.uint8)
glow_sheet = np.zeros_like(sheet)
anims = {}
for row, (name, count) in enumerate(ORDER):
    anims[name] = {"row": row, "frames": count}
    for i in range(count):
        cell = np.s_[row * CELL_H:(row + 1) * CELL_H, i * CELL_W:(i + 1) * CELL_W]
        sheet[cell], glow_sheet[cell] = frame(name, i)
Image.fromarray(sheet, "RGBA").save(os.path.join(OUT, "crawler.png"))
Image.fromarray(glow_sheet, "RGBA").save(os.path.join(OUT, "crawler_glow.png"))
meta = {"cell_w": CELL_W, "cell_h": CELL_H, "columns": 8, "anims": anims, "feet_below_center": FEET_BELOW_CENTER}
json.dump(meta, open(os.path.join(OUT, "crawler.json"), "w"), indent=1)
print("wrote crawler.png", sheet.shape, meta["feet_below_center"])
