#!/usr/bin/env python3
"""Generates the seamless pixel-art terrain textures (+ normal maps) into assets/.

Run:  python3 tools/gen_textures.py
Style: chunky stones with baked top-left light, crisp cracks, limited palettes.
"""
import os
import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "terrain")
os.makedirs(OUT, exist_ok=True)


def hexc(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32)


def value_noise(size, cells, rng):
    """Tileable smooth value noise in [0,1]."""
    grid = rng.random((cells, cells))
    t = np.arange(size) / size * cells
    i0 = np.floor(t).astype(int)
    f = t - i0
    f = f * f * (3 - 2 * f)
    i1 = (i0 + 1) % cells
    i0 %= cells
    a = grid[np.ix_(i0, i0)]
    b = grid[np.ix_(i0, i1)]
    c = grid[np.ix_(i1, i0)]
    d = grid[np.ix_(i1, i1)]
    fy = f[:, None]
    fx = f[None, :]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fractal(size, base_cells, octaves, rng):
    out = np.zeros((size, size))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += value_noise(size, base_cells * 2 ** o, rng) * amp
        tot += amp
        amp *= 0.5
    return out / tot


def voronoi(size, n, rng, jitter_scale=None):
    """Tileable voronoi: returns nearest index, d1, d2, offset-to-seed (dy, dx)."""
    seeds = rng.random((n, 2)) * size
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) + 0.5
    if jitter_scale is not None:   # wobble the stone shapes so they're not polygons
        yy = yy + jitter_scale[0]
        xx = xx + jitter_scale[1]
    d1 = np.full((size, size), 1e9)
    d2 = np.full((size, size), 1e9)
    idx = np.zeros((size, size), dtype=int)
    ody = np.zeros((size, size))
    odx = np.zeros((size, size))
    for k, (sy, sx) in enumerate(seeds):
        for oy in (-size, 0, size):
            for ox in (-size, 0, size):
                dy = yy - (sy + oy)
                dx = xx - (sx + ox)
                d = np.sqrt(dy * dy + dx * dx)
                closer = d < d1
                d2 = np.where(closer, d1, np.minimum(d2, d))
                ody = np.where(closer, dy, ody)
                odx = np.where(closer, dx, odx)
                idx = np.where(closer, k, idx)
                d1 = np.where(closer, d, d1)
    return idx, d1, d2, ody, odx


def normals_from_height(h, strength):
    dx = (np.roll(h, 1, axis=1) - np.roll(h, -1, axis=1)) * strength
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * strength   # OpenGL (Y up)
    n = np.stack([dx, dy, np.ones_like(h)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return ((n * 0.5 + 0.5) * 255).astype(np.uint8)


def quantize(shade, levels):
    return np.clip(np.floor(shade * levels), 0, levels - 1).astype(int)


def stones(name, size, n, palette, crack, rng, vein=None, wobble=3.0, specks=None):
    jit = (fractal(size, 4, 3, rng) - 0.5) * wobble * 2, (fractal(size, 4, 3, rng) - 0.5) * wobble * 2
    idx, d1, d2, ody, odx = voronoi(size, n, rng, jit)
    edge = d2 - d1
    height = np.clip(edge / 5.0, 0, 1) ** 0.6           # stones bulge, cracks are low
    rough = fractal(size, 8, 3, rng)
    height = height * 0.85 + rough * 0.15
    # baked light from top-left: use slope of the height field
    gy = np.roll(height, -1, 0) - np.roll(height, 1, 0)
    gx = np.roll(height, -1, 1) - np.roll(height, 1, 1)
    light = 0.55 - (gx + gy) * 2.2 + (rough - 0.5) * 0.25
    stone_tone = rng.random(n)[idx] * 0.25                # each stone a slightly different tone
    shade = np.clip(light + stone_tone - 0.1, 0, 0.999)
    pal = np.stack([hexc(c) for c in palette])
    img = pal[quantize(shade, len(palette))]
    img[edge < 1.3] = hexc(crack)
    img[(edge >= 1.3) & (edge < 2.0)] = (pal[0] * 0.8)
    if vein is not None:
        v = fractal(size, 3, 4, rng)
        band = np.abs(v - 0.5) < 0.012
        img[band] = hexc(vein)
    if specks is not None:
        m = rng.random((size, size)) < specks[1]
        img[m & (edge > 2.5)] = hexc(specks[0])
    save(name, img, height, 6.0)


def dirt(name, size, palette, rng):
    n1 = fractal(size, 6, 4, rng)
    n2 = fractal(size, 16, 2, rng)
    shade = np.clip(n1 * 0.8 + n2 * 0.35 - 0.1, 0, 0.999)
    pal = np.stack([hexc(c) for c in palette])
    img = pal[quantize(shade, len(palette))]
    height = shade.copy()
    # pebbles: little stones with a highlight
    for _ in range(16):
        cy, cx = rng.integers(0, size, 2)
        r = rng.integers(2, 5)
        tone = rng.choice(["#5d5249", "#6e6157", "#4a4039"])
        for y in range(-r, r + 1):
            for x in range(-r, r + 1):
                if x * x + y * y <= r * r:
                    yy, xx = (cy + y) % size, (cx + x) % size
                    c = hexc(tone)
                    if x + y < -r * 0.6:
                        c = c * 1.3
                    elif x + y > r * 0.6:
                        c = c * 0.6
                    img[yy, xx] = np.clip(c, 0, 255)
                    height[yy, xx] = 0.9
    # roots: thin dark wiggly lines
    for _ in range(5):
        y, x = rng.integers(0, size, 2)
        for _ in range(rng.integers(20, 60)):
            img[y % size, x % size] = hexc("#1c120b")
            img[(y + 1) % size, x % size] = hexc("#2a1b11")
            height[y % size, x % size] = 0.2
            y += 1
            x += rng.integers(-1, 2)
    save(name, img, height, 4.0)


def wall(name, size, rng):
    """Big rough slabs for the cave back wall (darker, lower contrast)."""
    stones(name, size, 22, ["#14100e", "#1b1512", "#231b16", "#2c221b"], "#090706", rng, wobble=5.0)


def mask(name, size, rng):
    """Tileable low-frequency noise used to cut holes in the back wall."""
    m = fractal(size, 4, 4, rng)
    m = (m - m.min()) / (m.max() - m.min())
    v = (m * 65535).astype(np.uint32)    # 16-bit precision split across R (high) and G (low)
    rgb = np.dstack([v >> 8, v & 255, np.zeros_like(v)]).astype(np.uint8)
    Image.fromarray(rgb, "RGB").save(os.path.join(OUT, name + ".png"))


def save(name, img, height, strength):
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB").save(os.path.join(OUT, name + ".png"))
    Image.fromarray(normals_from_height(height, strength), "RGB").save(os.path.join(OUT, name + "_n.png"))
    print("wrote", name)


if __name__ == "__main__":
    rng = np.random.default_rng(1337)
    S = 128
    dirt("dirt", S, ["#2a1b11", "#311f14", "#3a2618", "#442d1d", "#4f3422"], rng)
    stones("stone", S, 26, ["#262b36", "#323946", "#3f4858", "#4f5a6b", "#637085"], "#0e1015", rng,
           specks=("#7e8ca0", 0.004))
    stones("hard", S, 16, ["#17121f", "#211a2c", "#2c2439", "#3a3049", "#4a3e5e"], "#08060b", rng,
           vein="#6a2440", wobble=4.0)
    stones("bedrock", S, 12, ["#0a090d", "#100e14", "#16131b", "#1d1924"], "#030304", rng, wobble=4.0)
    wall("wall", 256, rng)
    mask("wall_mask", 512, rng)
