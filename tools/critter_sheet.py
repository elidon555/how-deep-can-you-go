#!/usr/bin/env python3
"""Turns the renders of tools/borer_blender.py, mite_blender.py or brood_blender.py into the
creature's pixel-art sheet, the same way as tools/crawler_sheet.py: stepped shading from the
clay pass, 1 px dark outline, a normal map (tools/normal_maps.py) and the glowing parts
(eyes, egg sac) kept unshaded and also written alone to <name>_glow.png (same layout).

Writes assets/sprites/<name>.png, <name>_n.png, <name>_glow.png and <name>.json.
Run:  python3 tools/critter_sheet.py borer|mite|brood <render_dir>
"""
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_maps import FLAT, cel_mult, normal_map  # noqa: E402

# per creature: cell size, floor offset (as in its *_blender.py), rows, glow colours (flat
# colours from the blender script's COLORS that light up: "glow" ones are drawn unshaded,
# "glow_shaded" ones keep their shading in the sprite and go into the glow layer as shaded)
CREATURES = {
    "borer": dict(cell=(80, 48), feet=16, columns=8,
                  order=[("walk", 8), ("burrow", 6), ("bite", 4), ("die", 4)],
                  glow=["#ffb020"]),
    "mite": dict(cell=(24, 16), feet=5, columns=4,
                 order=[("run", 4), ("die", 3)],
                 glow=["#ff2a24"]),
    "brood": dict(cell=(192, 128), feet=54, columns=8,
                  order=[("idle", 6), ("walk", 8), ("spit", 6), ("slam", 6), ("hurt", 2), ("die", 6)],
                  glow=["#c8ff60"], glow_shaded=["#a6dc56", "#e0fa96"]),
}
OUTLINE = np.array([12, 9, 14, 255], dtype=np.uint8)


def rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], np.float32)


def frame(src, name, i, cw, ch, glow_keys, shaded_keys=()):
    flat = np.array(Image.open(f"{src}/{name}_{i}_flat.png").convert("RGBA")).astype(np.float32)
    clay = np.array(Image.open(f"{src}/{name}_{i}_clay.png").convert("RGB")).astype(np.float32) / 255
    solid = flat[..., 3] > 128
    col = flat[..., :3] * cel_mult(clay.mean(axis=-1))[..., None]
    glow = np.zeros(solid.shape, bool)
    for key in glow_keys:
        g = (np.abs(flat[..., :3] - key).sum(-1) < 40) & solid
        col[g] = key
        glow |= g
    for key in shaded_keys:
        glow |= (np.abs(flat[..., :3] - key).sum(-1) < 40) & solid
    out = np.zeros((ch, cw, 4), np.uint8)
    out[..., :3] = np.clip(col, 0, 255).astype(np.uint8)
    out[..., 3] = np.where(solid, 255, 0)
    s = solid
    n = np.zeros_like(s)
    n[1:] |= s[:-1]; n[:-1] |= s[1:]; n[:, 1:] |= s[:, :-1]; n[:, :-1] |= s[:, 1:]
    out[n & ~s] = OUTLINE
    gl = np.zeros_like(out)
    gl[glow, :3] = out[glow, :3]
    gl[glow, 3] = 255
    return out, gl, normal_map(f"{src}/{name}_{i}_normal.png", out)


def main():
    name, src = sys.argv[1], sys.argv[2]
    c = CREATURES[name]
    cw, ch = c["cell"]
    cols = c["columns"]
    keys = [rgb(h) for h in c["glow"]]
    shaded = [rgb(h) for h in c.get("glow_shaded", [])]
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "sprites")
    sheet = np.zeros((ch * len(c["order"]), cw * cols, 4), np.uint8)
    glow = np.zeros_like(sheet)
    normals = np.zeros_like(sheet)
    normals[..., :3] = FLAT          # empty cells: flat, transparent
    anims = {}
    for row, (anim, count) in enumerate(c["order"]):
        anims[anim] = {"row": row, "frames": count}
        for i in range(count):
            cell = np.s_[row * ch:(row + 1) * ch, i * cw:(i + 1) * cw]
            sheet[cell], glow[cell], normals[cell] = frame(src, anim, i, cw, ch, keys, shaded)
    Image.fromarray(sheet, "RGBA").save(os.path.join(out_dir, f"{name}.png"))
    Image.fromarray(glow, "RGBA").save(os.path.join(out_dir, f"{name}_glow.png"))
    Image.fromarray(normals, "RGBA").save(os.path.join(out_dir, f"{name}_n.png"))
    meta = {"cell_w": cw, "cell_h": ch, "columns": cols, "anims": anims, "feet_below_center": c["feet"]}
    json.dump(meta, open(os.path.join(out_dir, f"{name}.json"), "w"), indent=1)
    print(f"wrote {name}.png", sheet.shape[1::-1])


if __name__ == "__main__":
    main()
