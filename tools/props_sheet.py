#!/usr/bin/env python3
"""Turns the prop renders into pixel-art sprites: <name>.png (lit), <name>_n.png (normal map)
and <name>_glow.png (emissive parts).

Run:  python3 tools/props_sheet.py <render_dir>
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_maps import cel_mult, normal_map  # noqa: E402

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "props")
os.makedirs(OUT, exist_ok=True)
OUTLINE = np.array([12, 9, 14, 255], dtype=np.uint8)
GLOW_KEYS = [np.array(c) for c in ([255, 179, 71], [176, 108, 255], [79, 240, 208])]
TILE = {"rope": 16}   # rendered several tiles tall: keep one middle tile (rows TILE..2*TILE)

for flat_path in sorted(glob.glob(f"{SRC}/*_flat.png")):
    name = os.path.basename(flat_path)[:-9]
    flat = np.array(Image.open(flat_path).convert("RGBA")).astype(np.float32)
    clay = np.array(Image.open(f"{SRC}/{name}_clay.png").convert("RGB")).astype(np.float32) / 255
    solid = flat[..., 3] > 128
    lum = clay.mean(-1)
    mult = cel_mult(lum)
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
    normals = np.array(Image.open(f"{SRC}/{name}_normal.png").convert("RGBA"))
    if name in TILE:
        t = TILE[name]
        out, glow, flat, normals, h = out[t:2 * t], glow[t:2 * t], flat[t:2 * t], normals[t:2 * t], t
    Image.fromarray(out, "RGBA").save(f"{OUT}/{name}.png")
    Image.fromarray(normal_map(normals, out), "RGBA").save(f"{OUT}/{name}_n.png")
    if glow.any():
        g = np.zeros((h, w, 4), np.uint8)
        g[glow, :3] = np.clip(flat[..., :3][glow] * 1.0, 0, 255)
        g[glow, 3] = 255
        Image.fromarray(g, "RGBA").save(f"{OUT}/{name}_glow.png")
    print("wrote", name, "(+glow)" if glow.any() else "")
