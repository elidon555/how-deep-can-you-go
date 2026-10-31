"""Shared by every *_sheet.py script: the baked cel shading and the normal maps.

Normal maps (X_n.png next to X.png, same size and layout) are for Godot 4 2D CanvasTexture:
tangent space, R = +x right, G = +y UP (OpenGL), B = toward the camera, so a pixel facing
the camera is (128, 128, 255). Transparent pixels are (128, 128, 255) with alpha 0 and the
1 px outline stays flat. Normals are snapped to a few directions so in-game lighting stays
crisp, stepped pixel art instead of smooth gradients.
"""
import math

import numpy as np
from PIL import Image

# The game lights sprites itself now, so the baked cel bands are softened toward flat colour:
# 1.0 = the original stepped bands, 0.0 = no baked shading at all.
BAKED_CONTRAST = 0.6
FLAT = np.array([128, 128, 255], np.uint8)
OUTLINE_RGB = np.array([12, 9, 14], np.uint8)


def cel_mult(lum, contrast=BAKED_CONTRAST):
    """Brightness multiplier per pixel from the clay pass: 4 tone bands, softened by contrast."""
    mult = np.select([lum > 0.78, lum > 0.5, lum > 0.27], [1.12, 0.92, 0.72], 0.52)
    return 1 + (mult - 1) * contrast


def _directions():
    """Facing the camera, plus rings tilted 30 and 60 degrees, 8 directions each."""
    dirs = [(0.0, 0.0, 1.0)]
    for tilt in (30, 60):
        t = math.radians(tilt)
        for k in range(8):
            a = k * math.pi / 4
            dirs.append((math.sin(t) * math.cos(a), math.sin(t) * math.sin(a), math.cos(t)))
    return np.array(dirs, np.float32)


DIRS = _directions()


def encode(n):
    return np.clip(np.round(n * 127.5 + 127.5), 0, 255).astype(np.uint8)


def normal_map(render, colour):
    """render: the Blender normal pass (path or HxWx4 array); colour: the finished RGBA sprite
    (its alpha and outline pixels decide where the normals go). Returns the HxWx4 normal map."""
    if isinstance(render, str):
        render = np.array(Image.open(render).convert("RGBA"))
    n = render[..., :3].astype(np.float32) / 255 * 2 - 1
    n[..., 2] = np.maximum(n[..., 2], 0.05)           # never facing away from the viewer
    n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-6
    snapped = DIRS[np.argmax(n @ DIRS.T, axis=-1)]
    out = np.zeros(colour.shape[:2] + (4,), np.uint8)
    out[..., :3] = encode(snapped)
    alpha = colour[..., 3]
    outline = (colour[..., :3] == OUTLINE_RGB).all(-1)
    flat = (alpha == 0) | outline | (render[..., 3] < 128)
    out[flat, :3] = FLAT
    out[..., 3] = alpha
    return out
