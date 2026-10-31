#!/usr/bin/env python3
"""Turns the boss renders into pixel art (cel shading + 1 px outline like the miner), glow
layers and normal maps (tools/normal_maps.py):
  assets/sprites/eye.png, eye_n.png, eye_glow.png (only the iris) + eye.json
  assets/sprites/vein.png, vein_n.png, vein_glow.png (crystals and core) + vein.json
Run:  python3 tools/eye_sheet.py <render_dir>
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
KEY = lambda h: np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)])        # noqa: E731
# unshaded colours; the glowing ones also go to the _glow layer
EYE_GLOW = [KEY(c) for c in ("#d8c878", "#8a44b8", "#a8963e", "#b0a25e", "#6a3890", "#857a4a", "#4e2e66")]
EYE_UNLIT = EYE_GLOW + [KEY("#fff8ec")]                                   # + the wet highlight
VEIN_GLOW = [KEY(c) for c in ("#c070ff", "#8a50b8", "#ff5a8a")]
SHEETS = {
    "eye": (160, 96, 6, [("closed", 2), ("opening", 6), ("open_look", 5), ("hurt", 2), ("dying", 6), ("blink", 3)],
            EYE_UNLIT, EYE_GLOW,
            "bottom-centre of the cell = the floor surface line under the eye's centre; the eye bulges ~75 px up"),
    "vein": (36, 30, 4, [("pulse", 4), ("burst", 3)], VEIN_GLOW, VEIN_GLOW,
             "bottom-centre of the cell = the floor surface line"),
}


def near(flat, keys):
    m = np.zeros(flat.shape[:2], bool)
    for k in keys:
        m |= np.abs(flat[..., :3] - k).sum(-1) < 30
    return m


def frame(name, unlit, glow_keys, w, h):
    flat = np.array(Image.open(f"{SRC}/{name}_flat.png").convert("RGBA")).astype(np.float32)
    clay = np.array(Image.open(f"{SRC}/{name}_clay.png").convert("RGB")).astype(np.float32) / 255
    solid = flat[..., 3] > 128
    rgb = flat[..., :3] * cel_mult(clay.mean(-1))[..., None]
    keep = near(flat, unlit) & solid
    rgb[keep] = flat[..., :3][keep]
    out = np.zeros((h, w, 4), np.uint8)
    out[..., :3] = np.clip(rgb, 0, 255)
    out[..., 3] = np.where(solid, 255, 0)
    n = np.zeros_like(solid)
    n[1:] |= solid[:-1]; n[:-1] |= solid[1:]; n[:, 1:] |= solid[:, :-1]; n[:, :-1] |= solid[:, 1:]
    out[n & ~solid] = OUTLINE
    g = near(flat, glow_keys) & solid
    glow = np.zeros_like(out)
    glow[g, :3] = flat[..., :3][g]
    glow[g, 3] = 255
    return out, glow, normal_map(f"{SRC}/{name}_normal.png", out)


for sheet_name, (w, h, cols, order, unlit, glow_keys, note) in SHEETS.items():
    sheet = np.zeros((h * len(order), w * cols, 4), np.uint8)
    glow = np.zeros_like(sheet)
    normals = np.zeros_like(sheet)
    normals[..., :3] = FLAT
    anims = {}
    for row, (anim, count) in enumerate(order):
        anims[anim] = {"row": row, "frames": count}
        for i in range(count):
            cell = np.s_[row * h:(row + 1) * h, i * w:(i + 1) * w]
            sheet[cell], glow[cell], normals[cell] = frame(f"{sheet_name}_{anim}_{i}", unlit, glow_keys, w, h)
    Image.fromarray(sheet, "RGBA").save(f"{OUT}/{sheet_name}.png")
    Image.fromarray(glow, "RGBA").save(f"{OUT}/{sheet_name}_glow.png")
    Image.fromarray(normals, "RGBA").save(f"{OUT}/{sheet_name}_n.png")
    json.dump({"cell_w": w, "cell_h": h, "columns": cols, "anims": anims, "anchor": note},
              open(f"{OUT}/{sheet_name}.json", "w"), indent=1)
    print("wrote", sheet_name, sheet.shape[1::-1])
