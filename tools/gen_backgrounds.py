#!/usr/bin/env python3
"""Generates the parallax background layers into assets/bg/.

Cave layers tile in both directions (white silhouettes + alpha, tinted in game).
Surface layers tile horizontally (hills and a dead forest), bottom = horizon.
Run:  python3 tools/gen_backgrounds.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "bg")
os.makedirs(OUT, exist_ok=True)


def value_noise(h, w, cy, cx, rng):
    grid = rng.random((cy, cx))
    ty = np.arange(h) / h * cy
    tx = np.arange(w) / w * cx
    iy, ix = np.floor(ty).astype(int), np.floor(tx).astype(int)
    fy, fx = ty - iy, tx - ix
    fy, fx = fy * fy * (3 - 2 * fy), fx * fx * (3 - 2 * fx)
    iy1, ix1 = (iy + 1) % cy, (ix + 1) % cx
    iy, ix = iy % cy, ix % cx
    a, b = grid[np.ix_(iy, ix)], grid[np.ix_(iy, ix1)]
    c, d = grid[np.ix_(iy1, ix)], grid[np.ix_(iy1, ix1)]
    fy, fx = fy[:, None], fx[None, :]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fractal(h, w, cy, cx, octaves, rng):
    out, amp, tot = np.zeros((h, w)), 1.0, 0.0
    for o in range(octaves):
        out += value_noise(h, w, cy * 2 ** o, cx * 2 ** o, rng) * amp
        tot += amp
        amp *= 0.5
    return out / tot


def spikes(mask, rng, count, max_len, down=True):
    """Stalactites (down) / stalagmites (up) growing from silhouette edges."""
    h, w = mask.shape
    img = Image.fromarray((mask * 255).astype(np.uint8), "L")
    dr = ImageDraw.Draw(img)
    tries = 0
    placed = 0
    while placed < count and tries < count * 40:
        tries += 1
        x, y = int(rng.integers(0, w)), int(rng.integers(1, h - 1))
        if down and not (mask[y, x] and not mask[(y + 1) % h, x]):
            continue
        if not down and not (mask[y, x] and not mask[(y - 1) % h, x]):
            continue
        length = int(rng.integers(max_len // 4, max_len))
        half = max(2, int(length * rng.uniform(0.08, 0.2)))
        tip = y + length if down else y - length
        bend = int(rng.integers(-half, half + 1))
        for ox in (-w, 0, w):        # wrap horizontally
            for oy in (-h, 0, h):    # and vertically
                dr.polygon([(x - half + ox, y + oy), (x + half + ox, y + oy), (x + bend + ox, tip + oy)], fill=255)
        placed += 1
    return np.array(img) > 127


def shade(mask, rng, base, rim, tex_amount):
    """Flat silhouette with a lit top rim and subtle texture -> RGBA (white-ish, tinted in game)."""
    h, w = mask.shape
    n = fractal(h, w, 16, 16, 3, rng)
    v = np.full((h, w), base) + (n - 0.5) * tex_amount
    up = np.roll(mask, 1, 0)          # pixel above
    up2 = np.roll(mask, 2, 0)
    top_edge = mask & (~up | ~up2)
    left_edge = mask & ~np.roll(mask, 1, 1)
    v = np.where(top_edge, rim, v)
    v = np.where(left_edge & ~top_edge, (v + rim) / 2, v)
    g = (np.clip(v, 0, 1) * 255).astype(np.uint8)
    a = (mask * 255).astype(np.uint8)
    return Image.fromarray(np.dstack([g, g, g, a]), "RGBA")


def cave_layer(name, size, rng, density, stretch, spike_n, spike_len, base, rim):
    # vertically stretched noise -> pillars, curtains and hanging formations
    n = fractal(size, size, max(2, int(4 / stretch)), 6, 4, rng)
    mask = n > np.quantile(n, 1.0 - density)
    mask = spikes(mask, rng, spike_n, spike_len, down=True)
    mask = spikes(mask, rng, spike_n // 2, spike_len // 2, down=False)
    shade(mask, rng, base, rim, 0.12).save(os.path.join(OUT, name + ".png"))
    print("wrote", name, f"{mask.mean():.0%} solid")


def hills(name, w, h, rng, base_y, amp, freq, base, rim):
    n = fractal(1, w, 1, freq, 4, rng)[0]
    tops = (base_y - n * amp).astype(int)
    yy = np.arange(h)[:, None]
    mask = yy >= tops[None, :]
    shade(mask, rng, base, rim, 0.06).save(os.path.join(OUT, name + ".png"))
    print("wrote", name)


def dead_forest(name, w, h, rng, count):
    img = Image.new("L", (w, h), 0)
    dr = ImageDraw.Draw(img)
    ground = h - 10
    dr.rectangle([0, ground, w, h], fill=255)

    def branch(x, y, ang, length, width, depth):
        if depth == 0 or length < 3:
            return
        x2 = x + np.cos(ang) * length
        y2 = y - np.sin(ang) * length
        for ox in (-w, 0, w):
            dr.line([(x + ox, y), (x2 + ox, y2)], fill=255, width=max(1, int(width)))
        for _ in range(2 if depth > 1 else 1):
            branch(x2, y2, ang + rng.uniform(-0.8, 0.8), length * rng.uniform(0.55, 0.75), width * 0.65, depth - 1)

    for _ in range(count):
        x = rng.uniform(0, w)
        hgt = rng.uniform(40, 110)
        branch(x, ground, np.pi / 2 + rng.uniform(-0.12, 0.12), hgt * 0.45, rng.uniform(3, 6), 5)
    mask = np.array(img) > 127
    shade(mask, rng, 0.5, 0.62, 0.05).save(os.path.join(OUT, name + ".png"))
    print("wrote", name)


if __name__ == "__main__":
    rng = np.random.default_rng(2024)
    # far -> near. Brighter base = more fog (tinted per depth in game)
    cave_layer("cave_far", 512, rng, 0.42, 1.8, 70, 90, 0.85, 1.0)
    cave_layer("cave_mid", 512, rng, 0.32, 1.4, 55, 80, 0.75, 0.95)
    cave_layer("cave_near", 512, rng, 0.22, 1.1, 40, 70, 0.65, 0.9)
    hills("hills_far", 1024, 160, rng, 120, 70, 3, 0.8, 0.9)
    hills("hills_near", 1024, 160, rng, 135, 45, 5, 0.6, 0.75)
    dead_forest("forest", 1024, 160, rng, 26)
