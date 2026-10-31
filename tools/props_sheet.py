#!/usr/bin/env python3
"""Turns the prop renders into pixel-art sprites: <name>.png (lit) + <name>_glow.png (emissive parts).

Run:  python3 tools/props_sheet.py <render_dir>
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "props")
os.makedirs(OUT, exist_ok=True)
OUTLINE = np.array([12, 9, 14, 255], dtype=np.uint8)
GLOW_KEYS = [np.array(c) for c in ([255, 179, 71], [176, 108, 255], [79, 240, 208])]

for flat_path in sorted(glob.glob(f"{SRC}/*_flat.png")):
    name = os.path.basename(flat_path)[:-9]
    flat = np.array(Image.open(flat_path).convert("RGBA")).astype(np.float32)
    clay = np.array(Image.open(f"{SRC}/{name}_clay.png").convert("RGB")).astype(np.float32) / 255
    solid = flat[..., 3] > 128
    lum = clay.mean(-1)
    mult = np.select([lum > 0.78, lum > 0.5, lum > 0.27], [1.12, 0.92, 0.72], 0.52)
    rgb = flat[..., :3] * mult[..., None]
    glow = np.zeros(solid.shape, bool)
    for k in GLOW_KEYS:
        glow |= np.abs(flat[..., :3] - k).sum(-1) < 40
    glow &= solid
    rgb[glow] = flat[..., :3][glow]
    h, w = solid.shape
    out = np.zeros((h, w, 4), np.uint8)
    out[..., :3] = np.clip(rgb, 0, 255)
    out[..., 3] = np.where(solid, 255, 0)
    n = np.zeros_like(solid)
    n[1:] |= solid[:-1]; n[:-1] |= solid[1:]; n[:, 1:] |= solid[:, :-1]; n[:, :-1] |= solid[:, 1:]
    out[n & ~solid] = OUTLINE
    Image.fromarray(out, "RGBA").save(f"{OUT}/{name}.png")
    if glow.any():
        g = np.zeros((h, w, 4), np.uint8)
        g[glow, :3] = np.clip(flat[..., :3][glow] * 1.0, 0, 255)
        g[glow, 3] = 255
        Image.fromarray(g, "RGBA").save(f"{OUT}/{name}_glow.png")
    print("wrote", name, "(+glow)" if glow.any() else "")
