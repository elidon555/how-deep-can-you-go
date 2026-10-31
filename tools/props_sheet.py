#!/usr/bin/env python3
"""Turns the prop renders into pixel-art sprites: <name>.png (lit), <name>_n.png (normal map)
and <name>_glow.png (emissive parts).

Run:  python3 tools/props_sheet.py <render_dir>
"""
import glob
import json
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
GLOW_KEYS = [np.array(c) for c in ([255, 179, 71], [176, 108, 255], [79, 240, 208], [255, 122, 26], [255, 208, 96],
                                    [255, 244, 200], [255, 58, 42], [255, 200, 168], [232, 64, 26],   # spark, flare, fire
                                    [90, 232, 240], [240, 96, 216], [159, 248, 255])]                 # fungi, ice
STRIPS = {"lava": 8, "fire": 8}  # animated props: <name>_0.. frames packed into one strip + <name>.json
GLOW_DIM = {"ice_crystal": 0.45}  # faint glows: the _glow layer is darkened by this factor
TILE = {"rope": 16}   # rendered several tiles tall: keep one middle tile (rows TILE..2*TILE)

def convert(name):
    """Pixel art for one render: (sprite, normal map, glow layer or None)."""
    flat = np.array(Image.open(f"{SRC}/{name}_flat.png").convert("RGBA")).astype(np.float32)
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
    g = None
    if glow.any():
        g = np.zeros((h, w, 4), np.uint8)
        g[glow, :3] = np.clip(flat[..., :3][glow] * GLOW_DIM.get(name, 1.0), 0, 255)
        g[glow, 3] = 255
    return out, normal_map(normals, out), g


def save(name, out, normals, glow):
    Image.fromarray(out, "RGBA").save(f"{OUT}/{name}.png")
    Image.fromarray(normals, "RGBA").save(f"{OUT}/{name}_n.png")
    if glow is not None:
        Image.fromarray(glow, "RGBA").save(f"{OUT}/{name}_glow.png")
    print("wrote", name, out.shape[1::-1], "(+glow)" if glow is not None else "")


names = sorted(os.path.basename(p)[:-9] for p in glob.glob(f"{SRC}/*_flat.png"))
strip_frames = {f"{k}_{i}" for k, n in STRIPS.items() for i in range(n)}
for name in names:
    if name not in strip_frames:
        save(name, *convert(name))
for name, count in STRIPS.items():            # animated: frames side by side, glow strip alongside
    if f"{name}_0" not in names:              # not in this render set
        continue
    frames = [convert(f"{name}_{i}") for i in range(count)]
    h, w = frames[0][0].shape[:2]
    glows = [f[2] if f[2] is not None else np.zeros((h, w, 4), np.uint8) for f in frames]
    save(name, np.concatenate([f[0] for f in frames], 1), np.concatenate([f[1] for f in frames], 1),
         np.concatenate(glows, 1))
    json.dump({"frames": count, "frame_w": w, "frame_h": h}, open(f"{OUT}/{name}.json", "w"), indent=1)
