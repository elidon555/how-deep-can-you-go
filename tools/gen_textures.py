#!/usr/bin/env python3
"""Generates the seamless pixel-art terrain textures (+ normal maps) into assets/terrain/.

Run:  python3 tools/gen_textures.py
Style: hand-pixelled look. Every material is built from designed shapes (strata, plates,
basalt columns, slabs, pebbles, roots, fossils) laid out on a torus so the 128 px tiles wrap,
then shaded from one height field with a baked top-left light and mapped onto a small
hue-shifted palette. The same height field becomes the normal map, so the lamp catches the
bevels and crack grooves that are painted in.
"""
import os
import numpy as np
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "terrain")
os.makedirs(OUT, exist_ok=True)

LIGHT = np.array([-0.55, 0.6, 0.58])          # baked light: from the top-left (x right, y up, z out)
LIGHT /= np.linalg.norm(LIGHT)
NB8 = ((0, 1, 1.0), (0, -1, 1.0), (1, 0, 1.0), (-1, 0, 1.0),
       (1, 1, 1.414), (1, -1, 1.414), (-1, 1, 1.414), (-1, -1, 1.414))


# ---------------------------------------------------------------- noise / fields (all tileable)
def hexc(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32)


def value_noise(size, cells, rng, cells_y=None):
    """Tileable smooth value noise in [0,1] (optionally with a different cell count in y)."""
    cy = cells_y or cells
    grid = rng.random((cy, cells))

    def axis(n):
        t = np.arange(size) / size * n
        i0 = np.floor(t).astype(int)
        f = t - i0
        return i0 % n, (i0 + 1) % n, f * f * (3 - 2 * f)
    y0, y1, fy = axis(cy)
    x0, x1, fx = axis(cells)
    fy, fx = fy[:, None], fx[None, :]
    a, b = grid[np.ix_(y0, x0)], grid[np.ix_(y0, x1)]
    c, d = grid[np.ix_(y1, x0)], grid[np.ix_(y1, x1)]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fractal(size, base_cells, octaves, rng, cells_y=None):
    out = np.zeros((size, size))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += value_noise(size, base_cells * 2 ** o, rng, cells_y and cells_y * 2 ** o) * amp
        tot += amp
        amp *= 0.5
    return out / tot


def wave(size, cells, rng, amp):
    """A tileable 1-D wobble (length `size`) in [-amp, amp]."""
    return (fractal(size, cells, 3, rng)[0] - 0.5) * 2 * amp


def dist_to(solid, maxd=12):
    """Chamfer distance (px) from every solid pixel to the nearest non-solid one, wrapping."""
    d = np.where(solid, float(maxd), 0.0)
    for _ in range(maxd + 2):
        m = d
        for dy, dx, w in NB8:
            m = np.minimum(m, np.roll(d, (dy, dx), (0, 1)) + w)
        m = np.where(solid, np.minimum(m, maxd), 0.0)
        if np.array_equal(m, d):
            break
        d = m
    return d


def borders(label):
    """Pixels whose right or lower neighbour belongs to another region (a 1 px seam)."""
    return (label != np.roll(label, -1, 1)) | (label != np.roll(label, -1, 0))


def voronoi(size, seeds, sy=1.0, warp=None):
    """Tileable voronoi over given seeds; `sy` < 1 squashes y (tall cells).
    Returns the nearest-seed index per pixel."""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) + 0.5
    if warp is not None:
        yy, xx = yy + warp[0], xx + warp[1]
    d1 = np.full((size, size), 1e9)
    idx = np.zeros((size, size), dtype=int)
    for k, (py, px) in enumerate(seeds):
        for oy in (-size, 0, size):
            for ox in (-size, 0, size):
                dy = (yy - (py + oy)) * sy
                dx = xx - (px + ox)
                d = dy * dy + dx * dx
                closer = d < d1
                d1 = np.where(closer, d, d1)
                idx = np.where(closer, k, idx)
    return idx


def normals(h, strength):
    """Height -> unit normals (x right, y up), same convention as the encoder below."""
    dx = (np.roll(h, 1, axis=1) - np.roll(h, -1, axis=1)) * strength
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * strength   # OpenGL (Y up)
    n = np.stack([dx, dy, np.ones_like(h)], axis=-1)
    return n / np.linalg.norm(n, axis=-1, keepdims=True)


def baked_light(h, strength):
    """How much more (or less) a pixel faces the top-left light than a flat one does."""
    return normals(h, strength) @ LIGHT - LIGHT[2]


def palette(*hexes):
    return np.stack([hexc(c) for c in hexes])


def ramp(base, n=5):
    """A small hue-shifted ramp around one colour: cool dark shadows, warm light highlights."""
    b = hexc(base)
    out = []
    for t in np.linspace(-1, 1, n):
        if t < 0:
            c = b * (1 + 0.55 * t) * np.array([0.92, 0.96, 1.08]) ** (-t)
        else:
            c = b * (1 + 0.6 * t) * np.array([1.06, 1.02, 0.94]) ** t
        out.append(np.clip(c, 0, 255))
    return np.stack(out)


# ---------------------------------------------------------------- stamps (small designed objects)
def stamp_mask(size, cy, cx, r, fn):
    """Evaluate fn(dy, dx) -> bool on a (2r+1)^2 box around (cy, cx), wrapped. Returns ys, xs, dy, dx."""
    o = np.arange(-r, r + 1)
    dy, dx = np.meshgrid(o, o, indexing="ij")
    m = fn(dy.astype(float), dx.astype(float))
    return (cy + dy[m]) % size, (cx + dx[m]) % size, dy[m], dx[m]


def shade_stamp(img, height, ys, xs, cols, lift, cast=None):
    """Paint a small solid shape: lit up-left rim, shadowed down-right rim, optional cast shadow
    on what's behind it. `cols` = [dark, shadow, base, light, highlight]."""
    size = img.shape[0]
    occ = np.zeros((size, size), bool)
    occ[ys, xs] = True
    up, left = np.roll(occ, 1, 0), np.roll(occ, 1, 1)
    down, right = np.roll(occ, -1, 0), np.roll(occ, -1, 1)
    lit = occ & (~up | ~left)
    dark = occ & (~down | ~right) & ~lit
    tone = np.where(lit, 3, np.where(dark, 1, 2))
    # one highlight pixel near the top-left of the shape
    hi = occ & up & left & ~np.roll(up, 1, 0) & ~np.roll(left, 1, 1)
    tone = np.where(hi, 4, tone)
    if cast is not None:      # shadow it drops down-right onto the surface behind
        c = np.roll(np.roll(occ, 1, 0), 1, 1) & ~occ
        img[c] *= cast
    img[occ] = cols[tone[occ]]
    height[occ] = np.maximum(height[occ], lift)
    return occ


def pebble(img, height, rng, cy, cx, rad, base, lift=0.9, cast=0.62):
    """A rounded stone with a lumpy outline, shaded as a dome lit from the top-left."""
    size = img.shape[0]
    rx, ry = rad * rng.uniform(0.9, 1.4), rad * rng.uniform(0.65, 1.0)
    ang = rng.uniform(-0.6, 0.6)
    lump = rng.uniform(0, 6.28, 3)
    ca, sa = np.cos(ang), np.sin(ang)

    def inside(dy, dx):
        u, v = dx * ca + dy * sa, -dx * sa + dy * ca
        a = np.arctan2(v, u)
        k = 1 + 0.12 * np.sin(2 * a + lump[0]) + 0.08 * np.sin(3 * a + lump[1])
        return (u / rx) ** 2 + (v / ry) ** 2 <= k * k
    R = int(np.ceil(max(rx, ry) * 1.25)) + 1
    ys, xs, dy, dx = stamp_mask(size, cy, cx, R, inside)
    if len(ys) == 0:
        return
    cols = ramp(base)
    occ = np.zeros((size, size), bool)
    occ[ys, xs] = True
    # dome normal -> tone
    nz = np.sqrt(np.clip(1 - (dx / (rx + 0.5)) ** 2 - (dy / (ry + 0.5)) ** 2, 0.05, 1))
    lam = (dx / (rx + 0.5)) * LIGHT[0] - (dy / (ry + 0.5)) * LIGHT[1] + nz * LIGHT[2]
    tone = np.clip(np.round(1 + lam * 3.0), 1, 4).astype(int)
    edge = ~(np.roll(occ, -1, 0) & np.roll(occ, -1, 1))[ys, xs]   # bottom-right rim
    tone = np.where(edge & (tone < 3), 0, tone)
    sh = np.roll(np.roll(occ, 1, 0), 1, 1) & ~occ
    img[sh] *= cast
    img[ys, xs] = cols[tone]
    height[ys, xs] = np.maximum(height[ys, xs], lift * (0.4 + 0.6 * nz))


def walk(rng, y, x, steps, ang, turn, bias_ang=None, bias=0.0):
    """A wandering 1 px path (float positions), angle in radians (0 = right, pi/2 = down)."""
    pts = []
    for _ in range(steps):
        pts.append((y, x))
        ang += rng.normal(0, turn)
        if bias_ang is not None:
            ang += (bias_ang - ang) * bias
        y += np.sin(ang)
        x += np.cos(ang)
    return pts, ang


def save(name, img, height, strength):
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB").save(os.path.join(OUT, name + ".png"))
    n = normals(height, strength)
    Image.fromarray(((n * 0.5 + 0.5) * 255).astype(np.uint8), "RGB").save(os.path.join(OUT, name + "_n.png"))
    print("wrote", name)


# ---------------------------------------------------------------- shared: bedded plates
def plates(size, rng, rows, wmin, wmax, sy=2.0, p=3.0, jit=(1.5, 3.0), warp=2.0, warp_cells=6):
    """Bedded rock plates: a voronoi over seeds laid in rows (heights in `rows`, summing to size),
    with a squarish p-norm so cells come out as chunky blocks with rounded corners instead of
    polygons. Row seams kink from block to block, joints lean. Returns (label, row, row height)."""
    assert sum(rows) == size
    centres = np.cumsum([0] + rows[:-1]) + np.array(rows) / 2
    seeds, srow, sw = [], [], []
    for r, (cy, h) in enumerate(zip(centres, rows)):
        x = rng.uniform(0, size)
        end = x + size
        while x < end - wmin * 0.8:
            w = rng.uniform(wmin, wmax)
            if end - (x + w) < wmin * 0.8:
                w = end - x
            seeds.append((cy + rng.uniform(-1, 1) * min(jit[0], h * 0.2), x + w / 2 + rng.uniform(-1, 1) * jit[1]))
            srow.append(r)
            sw.append((rng.uniform(0.6, 1.5), rng.uniform(0.8, 1.25)))   # some bulge into the next bed
            x += w
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) + 0.5
    yy = yy + (fractal(size, warp_cells, 2, rng) - 0.5) * 2 * warp * 0.5
    xx = xx + (fractal(size, warp_cells, 2, rng) - 0.5) * 2 * warp
    best = np.full((size, size), 1e18)
    label = np.zeros((size, size), int)
    for k, (py, px) in enumerate(seeds):
        h = rows[srow[k]]
        for oy in (-size, 0, size):
            for ox in (-size, 0, size):
                dy = np.abs(yy - (py + oy)) / (h / 2) * (wmax / 2) * sy * sw[k][0]   # beds meet at row edges
                dx = np.abs(xx - (px + ox)) * sw[k][1]
                d = dx ** p + dy ** p
                closer = d < best
                best = np.where(closer, d, best)
                label = np.where(closer, k, label)
    srow = np.array(srow)
    return label, srow[label], np.array(rows)[srow[label]]


def chip_corners(gap, label, rng, count, size):
    """Knock small triangular chips out of block corners (where seams meet)."""
    cross = gap & (np.roll(gap, 1, 0) | np.roll(gap, -1, 0)) & (np.roll(gap, 1, 1) | np.roll(gap, -1, 1))
    ys, xs = np.nonzero(cross)
    if len(ys) == 0:
        return gap
    pick = rng.choice(len(ys), min(count, len(ys)), replace=False)
    g = gap.copy()
    for i in pick:
        r = int(rng.integers(1, 3))
        sy, sx = rng.choice([-1, 1]), rng.choice([-1, 1])
        for a in range(r + 1):
            for b in range(r + 1 - a):
                g[(ys[i] + sy * a) % size, (xs[i] + sx * b) % size] = True
    return g


# ---------------------------------------------------------------- materials
def dirt(name, S, rng):
    pal = palette("#140c07", "#1b110a", "#22160e", "#2a1b11", "#321f13", "#3b2617", "#452d1c",
                  "#503422", "#5c3d28")
    yy, xx = np.mgrid[0:S, 0:S]
    # strata: (height, kind, tone) -- kinds: loam (clumpy), clay (laminated), gravel, humus (dark)
    bands = [(19, "loam", 4.6), (7, "gravel", 4.4), (23, "clay", 5.4), (12, "humus", 3.4),
             (28, "loam", 4.8), (9, "clay", 5.6), (16, "gravel", 4.4), (14, "loam", 4.0)]
    assert sum(b[0] for b in bands) == S
    tops = np.cumsum([0] + [b[0] for b in bands[:-1]])
    wob = np.stack([wave(S, 2, rng, 3.5) + wave(S, 8, rng, 1.0) for _ in bands])
    bi = np.zeros((S, S), int)
    yb = (yy + np.round(wob[np.searchsorted(tops, yy, "right") - 1, xx]).astype(int)) % S
    for i, t in enumerate(tops):
        bi = np.where(yb >= t, i, bi)
    local = yb - tops[bi]
    tone = np.array([b[2] for b in bands])[bi].astype(float)
    kind = np.array([b[1] for b in bands])[bi]

    # clods: soft lumps shaded from a height field
    clod = fractal(S, 10, 2, rng)
    fine = fractal(S, 32, 1, rng)
    height = clod * 0.35 + fine * 0.08
    loam = (kind == "loam") | (kind == "humus")
    height = np.where(loam, height + (clod > 0.55) * 0.12, height)
    # clay: thin laminations (fine horizontal lines that pinch out)
    lam_on = fractal(S, 6, 2, rng, cells_y=24) > 0.52
    lam = (kind == "clay") & (local % 5 == 2) & lam_on
    height = np.where(lam, height - 0.1, height)
    # band contacts: a groove on top of each band
    contact = local == 0
    height = np.where(contact, height - 0.25, height)

    shade = tone + baked_light(height, 3.0) * 7 + (fine - 0.5) * 0.9
    shade = np.where(kind == "clay", shade + (clod - 0.5) * 0.6, shade)
    # damp patches: big soft areas one step darker, slightly cooler
    damp = fractal(S, 3, 3, rng)
    damp_m = damp > 0.6
    shade = np.where(damp_m, shade - 1.1, shade)
    shade = np.where(lam, shade - 1, shade)
    shade = np.where(contact, shade - 1.5, shade)
    shade = np.where(np.roll(contact, -1, 0) & ~contact, shade + 0.8, shade)   # lit lip above it
    idx = np.clip(np.round(shade), 0, len(pal) - 1).astype(int)
    img = pal[idx]
    img = np.where(damp_m[..., None], img * np.array([0.92, 0.95, 1.05]), img)

    # roots: fibres coming down from above, wrapping, with fine hair roots
    rootc = np.array([hexc("#5a412c"), hexc("#6b5038")])
    for _ in range(4):
        y, x = rng.uniform(0, S), rng.uniform(0, S)
        pts, _ = walk(rng, y, x, int(rng.integers(40, 90)), np.pi / 2 + rng.uniform(-0.5, 0.5), 0.18,
                      np.pi / 2, 0.06)
        for k, (py, px) in enumerate(pts):
            iy, ix = int(py) % S, int(px) % S
            img[iy, ix] = rootc[int(k % 7 == 0)]
            img[(iy + 1) % S, (ix + 1) % S] *= 0.6
            height[iy, ix] += 0.35
            if k < len(pts) * 0.4:         # thicker near the top
                img[iy, (ix + 1) % S] = rootc[0] * 0.8
                height[iy, (ix + 1) % S] += 0.25
            if rng.random() < 0.07:        # hair root
                hp, _ = walk(rng, py, px, int(rng.integers(5, 14)), np.pi / 2 + rng.choice([-1.1, 1.1]), 0.35)
                for qy, qx in hp[1:]:
                    jy, jx = int(qy) % S, int(qx) % S
                    img[jy, jx] = img[jy, jx] * 0.45 + rootc[0] * 0.55
                    height[jy, jx] += 0.12

    # pebbles: a few bigger stones scattered, lots of grit in the gravel bands
    stone_cols = ["#544a42", "#5f544b", "#4a413a", "#514c48", "#5c4e41"]
    gravel_px = np.argwhere(kind == "gravel")
    for _ in range(34):
        y, x = gravel_px[rng.integers(len(gravel_px))]
        pebble(img, height, rng, y, x, rng.uniform(0.8, 1.9), rng.choice(stone_cols), 0.6, 0.75)
    for _ in range(11):
        y, x = rng.integers(0, S, 2)
        pebble(img, height, rng, y, x, rng.uniform(2.2, 4.6), rng.choice(stone_cols), 0.95, 0.6)

    # a tiny bone and an ammonite, dim so they read as a find, not a sticker
    bone = ramp("#655d4e")
    cy, cx = 84, 22
    ang = 0.35
    def bone_fn(dy, dx):
        u, v = dx * np.cos(ang) + dy * np.sin(ang), -dx * np.sin(ang) + dy * np.cos(ang)
        shaft = (np.abs(u) <= 5.2) & (np.abs(v) <= 0.75)
        knobs = ((np.abs(u) - 5.6) ** 2 + (np.abs(v) - 1.0) ** 2 <= 1.6)
        return shaft | knobs
    ys, xs, _, _ = stamp_mask(S, cy, cx, 9, bone_fn)
    shade_stamp(img, height, ys, xs, bone, 0.7, cast=0.55)
    shell = ramp("#5e5548")
    cy, cx = 44, 101
    ys, xs, dy, dx = stamp_mask(S, cy, cx, 5, lambda dy, dx: dx * dx + dy * dy <= 13.5)
    shade_stamp(img, height, ys, xs, shell, 0.8, cast=0.55)
    for t in np.linspace(0.6, 4 * np.pi, 40):     # spiral groove
        r = 0.27 * t
        py, px = cy + int(round(r * np.sin(t))), cx + int(round(r * np.cos(t)))
        img[py % S, px % S] = shell[1]
        height[py % S, px % S] -= 0.15
    img[cy % S, cx % S] = shell[0]
    # a few vertebra-like bits: three little knuckles in a row
    for k in range(3):
        ys, xs, _, _ = stamp_mask(S, 31 + k, 58 + 3 * k, 1, lambda dy, dx: (np.abs(dy) + np.abs(dx)) <= 1)
        shade_stamp(img, height, ys, xs, bone * 0.8, 0.6, cast=0.7)
    save(name, img, height, 3.0)


def stone(name, S, rng):
    """Layered sedimentary rock: chunky bevelled plates in beds, thin shaly beds between,
    hairline cracks, pale calcite veins offset at the bed seams, a few embedded pebbles."""
    pal = palette("#0b0d12", "#151922", "#1e232d", "#282e3a", "#323946", "#3e4656", "#4c5668",
                  "#5c687c", "#717e93", "#8995a8")
    rows = [22, 7, 18, 26, 6, 19, 14, 16]
    label, _, rh = plates(S, rng, rows, 16, 46, sy=0.8, p=2.5, jit=(2.5, 5), warp=3.0, warp_cells=5)
    yy, xx = np.mgrid[0:S, 0:S]
    thin = rh <= 7
    gap = borders(label)
    gap = chip_corners(gap, label, rng, 16, S)
    wide = fractal(S, 8, 2, rng) > 0.66         # some seams open up into real cracks
    gap |= np.roll(gap, 1, 0) & wide & ~thin
    d = dist_to(~gap, 6)
    bw = np.where(thin, 1.5, 2.5)
    height = np.clip(d / bw, 0, 1) ** 0.8
    nb = label.max() + 1
    face = rng.choice([4.4, 5.4, 5.4, 6.2], nb)
    face[np.unique(label[thin])] = rng.choice([3, 4], len(np.unique(label[thin])))
    rough = fractal(S, 16, 2, rng)
    height += (rough - 0.5) * 0.12

    # inside the plates: faint bedding laminations and hairline cracks
    lwarp = np.round(wave(S, 3, rng, 1.5)).astype(int)[xx]
    lamin = ~thin & ((yy + lwarp) % 6 == 0) & (fractal(S, 5, 2, rng, cells_y=20) > 0.55) & (d > 2.5)
    height = np.where(lamin, height - 0.08, height)
    hair = np.zeros((S, S), bool)
    ys, xs = np.nonzero(gap & ~thin)
    for _ in range(8):
        i = rng.integers(len(ys))
        pts, _ = walk(rng, ys[i], xs[i], int(rng.integers(5, 12)), rng.uniform(0, 6.28), 0.45)
        for py, px in pts:
            hair[int(py) % S, int(px) % S] = True
    hair &= ~gap
    height = np.where(hair, height - 0.35, height)

    shade = face[label] + baked_light(height, 2.6) * 5.5 + (rough - 0.5) * 0.8
    shade = np.where(lamin, shade - 0.8, shade)
    shade = np.where(hair, shade - 2.2, shade)
    shade = np.where(np.roll(hair, 1, 0) & ~hair & ~gap, shade + 1, shade)  # lit lip under a crack
    shade = np.where(gap, 0, shade)
    idx = np.clip(np.round(shade), 0, len(pal) - 1).astype(int)
    img = pal[idx]

    # calcite veins: meandering, thicker in places, jumping sideways at every seam (little faults)
    vein = np.zeros((S, S), bool)
    for _ in range(2):
        y, x = rng.uniform(0, S, 2)
        ang = rng.choice([0.9, 2.2]) + rng.uniform(-0.2, 0.2)
        base = ang
        for k in range(150):
            iy, ix = int(y) % S, int(x) % S
            if gap[iy, ix]:
                x += rng.choice([-3, -2, 2, 3])
            else:
                vein[iy, ix] = True
                if np.sin(k * 0.21) > 0.6:
                    vein[iy, (ix + 1) % S] = True
            ang += rng.normal(0, 0.25) + (base - ang) * 0.15
            y += np.sin(ang)
            x += np.cos(ang)
    vein &= ~gap & (d > 1.2)
    vc = palette("#6c7a90", "#8b99ae")
    img[vein] = vc[(rough[vein] > 0.5).astype(int)]
    img[np.roll(vein, 1, 1) & np.roll(vein, 1, 0) & ~vein & ~gap] *= 0.8
    height = np.where(vein, height + 0.12, height)
    # small embedded pebbles (conglomerate bits)
    for _ in range(12):
        while True:
            y, x = rng.integers(0, S, 2)
            if d[y, x] > 3.5 and not thin[y, x] and not vein[y, x]:
                break
        pebble(img, height, rng, y, x, rng.uniform(1.0, 2.2),
               rng.choice(["#5a5a60", "#66605a", "#4e5866", "#6b6a70"]), 0.85, 0.75)
    save(name, img, height, 2.6)


def hard(name, S, rng):
    """Dense basalt: columns with lit/dark facets, broken by cross joints, a few glinting specks."""
    pal = palette("#07050a", "#0e0a13", "#15101c", "#1d1626", "#251d31", "#2f263d", "#3a304b",
                  "#473c5b", "#57496e", "#6a5a84")
    ncol = 8
    seeds = []
    for c in range(ncol):
        cx = (c + 0.5) * S / ncol + rng.uniform(-3, 3)
        n = int(rng.integers(3, 5))
        ys = np.sort(rng.uniform(0, S, n))
        for y in ys:
            seeds.append((y, cx + rng.uniform(-2.0, 2.0)))
    warp = (np.zeros((S, S)), np.tile(wave(S, 3, rng, 2.2)[:, None], (1, S)))   # columns lean/sway
    idx = voronoi(S, seeds, sy=0.16, warp=warp)
    gap = borders(idx)
    gap = chip_corners(gap, idx, rng, 12, S)
    d = dist_to(~gap, 8)
    # per row, how far to the column's left / right seam -> facet position across the column
    dl = np.zeros((S, S))
    dr = np.zeros((S, S))
    for x in range(-S, S):                       # two passes so the wrap is filled
        xi, prev = x % S, (x - 1) % S
        dl[:, xi] = np.where(gap[:, xi], 0, dl[:, prev] + 1)
    for x in range(2 * S, 0, -1):
        xi, nxt = x % S, (x + 1) % S
        dr[:, xi] = np.where(gap[:, xi], 0, dr[:, nxt] + 1)
    frac = dl / np.maximum(dl + dr, 1)
    # prism profile: narrow lit facet on the left, broad face, darker facet on the right
    prof = np.clip(np.minimum((frac - 0.0) / 0.22, (1.0 - frac) / 0.3), 0, 1)
    vert = np.clip(d / 2.2, 0, 1)                # bevel at the cross joints
    height = np.minimum(prof * 0.7 + 0.3, vert * 0.9 + 0.1) * 0.9
    rough = fractal(S, 12, 2, rng)
    height += (rough - 0.5) * 0.1
    nb = idx.max() + 1
    face = rng.choice([4.5, 4.5, 5.5, 5.5, 6.3], nb)
    shade = face[idx] + baked_light(height, 2.4) * 5.0
    shade = np.where(frac < 0.18, shade + 1.0, shade)     # crisp facet bands
    shade = np.where(frac > 0.8, shade - 1.0, shade)
    shade += (rough - 0.5) * 0.7
    # diagonal fractures across a few columns
    frac_m = np.zeros((S, S), bool)
    for _ in range(5):
        y, x = rng.integers(0, S, 2)
        pts, _ = walk(rng, y, x, int(rng.integers(10, 24)), rng.choice([0.5, 2.6]) + rng.uniform(-0.3, 0.3), 0.2)
        for py, px in pts:
            frac_m[int(py) % S, int(px) % S] = True
    frac_m &= ~gap
    shade = np.where(frac_m, shade - 2.5, shade)
    shade = np.where(np.roll(frac_m, 1, 0) & ~frac_m & ~gap, shade + 0.8, shade)
    height = np.where(frac_m, height - 0.3, height)
    shade = np.where(gap, 0, shade)
    pidx = np.clip(np.round(shade), 0, len(pal) - 1).astype(int)
    img = pal[pidx]
    # vesicles: tiny dark pores with a lit lower lip
    for _ in range(26):
        y, x = rng.integers(0, S, 2)
        if d[y, x] > 2:
            img[y, x] = pal[1]
            img[(y + 1) % S, x] = pal[min(pidx[y, x] + 1, len(pal) - 1)]
            height[y, x] -= 0.2
    # glints: a few mineral specks, little 4-point stars
    glint = palette("#cdb8ee", "#7d68a6", "#9fd0e0")
    placed = 0
    while placed < 8:
        y, x = rng.integers(0, S, 2)
        if d[y, x] < 3 or frac[y, x] > 0.75:
            continue
        img[y, x] = glint[2] if placed % 4 == 0 else glint[0]
        if placed % 3 == 0:
            for oy, ox in ((0, 1), (0, -1), (1, 0), (-1, 0)):
                img[(y + oy) % S, (x + ox) % S] = glint[1]
        height[y, x] += 0.2
        placed += 1
    save(name, img, height, 2.4)


def bedrock(name, S, rng):
    """Almost black and massive: a few huge blocks, heavy jagged cracks with branches."""
    pal = palette("#020203", "#060509", "#0a090d", "#0e0c12", "#121017", "#17141d", "#1c1823",
                  "#221e2a", "#2a2533")
    seeds = rng.random((6, 2)) * S
    warp = ((fractal(S, 4, 3, rng) - 0.5) * 14, (fractal(S, 4, 3, rng) - 0.5) * 14)
    idx = voronoi(S, seeds, 1.0, warp)
    seam = borders(idx)
    jag = fractal(S, 16, 2, rng)
    gap = seam | (np.roll(seam, 1, 0) & (jag > 0.42)) | (np.roll(seam, 1, 1) & (jag > 0.55))
    gap |= np.roll(seam, -1, 1) & (jag > 0.7)
    # branching secondary cracks running off the main ones
    hair = np.zeros((S, S), bool)
    ys, xs = np.nonzero(seam)
    for _ in range(14):
        i = rng.integers(len(ys))
        pts, _ = walk(rng, ys[i], xs[i], int(rng.integers(8, 26)), rng.uniform(0, 6.28), 0.3)
        for k, (py, px) in enumerate(pts):
            hair[int(py) % S, int(px) % S] = True
            if k < 5:
                hair[int(py + 1) % S, int(px) % S] = True
    hair &= ~gap
    d = dist_to(~gap, 8)
    height = np.clip(d / 3.5, 0, 1) ** 0.7
    mott = fractal(S, 5, 3, rng)
    height += (mott - 0.5) * 0.25
    height = np.where(hair, height - 0.3, height)
    # broad, shallow conchoidal scallops
    scal = fractal(S, 7, 1, rng)
    height += np.abs(scal - 0.5) * 0.25
    face = rng.choice([4, 4, 5], idx.max() + 1).astype(float)
    shade = face[idx] + baked_light(height, 2.2) * 5.0 + (mott - 0.5) * 1.8
    shade = np.where(hair, shade - 2.5, shade)
    shade = np.where(np.roll(hair, 1, 0) & ~hair, shade + 0.7, shade)
    shade = np.where(gap, 0, shade)
    shade = np.where(~gap & np.roll(gap, 1, 0) & (d < 1.5), shade + 1.6, shade)   # lit lower lip
    img = pal[np.clip(np.round(shade), 0, len(pal) - 1).astype(int)]
    save(name, img, height, 2.2)


def wall(name, S, rng):
    """Back wall behind caves: big bedded slabs, darker and calmer than the rock in front."""
    pal = palette("#070504", "#0c0908", "#110d0b", "#15110e", "#1a1512", "#1f1915", "#251e19",
                  "#2c241e", "#342a23")
    rows = [34, 12, 41, 22, 10, 47, 30, 14, 46]
    label, _, rh = plates(S, rng, rows, 30, 84, sy=0.8, p=2.3, jit=(5, 10), warp=6, warp_cells=4)
    yy, xx = np.mgrid[0:S, 0:S]
    thin = rh <= 14
    gap = borders(label)
    gap = chip_corners(gap, label, rng, 26, S)
    jag = fractal(S, 16, 2, rng)
    gap |= np.roll(gap, 1, 0) & (jag > 0.6)
    d = dist_to(~gap, 8)
    height = np.clip(d / 3.0, 0, 1) ** 0.8
    rough = fractal(S, 10, 3, rng)
    height += (rough - 0.5) * 0.3
    face = rng.choice([4.8, 4.8, 5.6], label.max() + 1)
    lwarp = np.round(wave(S, 3, rng, 2.5)).astype(int)[xx]
    lam = ~thin & ((yy + lwarp) % 8 == 0) & (fractal(S, 6, 2, rng, cells_y=30) > 0.5) & (d > 3)
    height = np.where(lam, height - 0.12, height)
    hair = np.zeros((S, S), bool)
    ys, xs = np.nonzero(gap)
    for _ in range(18):
        i = rng.integers(len(ys))
        pts, _ = walk(rng, ys[i], xs[i], int(rng.integers(8, 22)), rng.uniform(0, 6.28), 0.35)
        for py, px in pts:
            hair[int(py) % S, int(px) % S] = True
    hair &= ~gap
    height = np.where(hair, height - 0.3, height)
    shade = face[label] + baked_light(height, 2.4) * 4.0 + (rough - 0.5) * 1.4
    shade = np.where(lam, shade - 0.8, shade)
    shade = np.where(hair, shade - 2, shade)
    shade = np.where(gap, 0, shade)
    img = pal[np.clip(np.round(shade), 0, len(pal) - 1).astype(int)]
    for _ in range(18):
        while True:
            y, x = rng.integers(0, S, 2)
            if d[y, x] > 4:
                break
        pebble(img, height, rng, y, x, rng.uniform(1.0, 2.6), rng.choice(["#2a221c", "#302822", "#252019"]),
               0.8, 0.8)
    save(name, img, height, 2.4)


def save_glow(name, glow):
    """Emissive map for the bloom layer, same convention as the prop glows: RGB = light colour
    (intensity baked in), alpha 255 where it glows, fully transparent black elsewhere."""
    on = glow.max(-1) > 4
    out = np.zeros(glow.shape[:2] + (4,), np.uint8)
    out[..., :3] = np.where(on[..., None], np.clip(glow, 0, 255), 0).astype(np.uint8)
    out[..., 3] = np.where(on, 255, 0)
    Image.fromarray(out, "RGBA").save(os.path.join(OUT, name + "_glow.png"))
    print("wrote", name + "_glow", f"{on.mean():.1%} glowing")


def prism(img, height, glow, rng, cy, cx, ang, L, w, pal, glow_col):
    """One hexagonal crystal seen side-on: three long faces (lit / middle / shadow side), a
    pointed termination with two facets, bright ridges between faces. Painter's order."""
    S = img.shape[0]
    ay, ax = np.sin(ang), np.cos(ang)            # axis (image coords, y down)
    py, px = ax, -ay                             # across the crystal
    R = int(L + w + 3)
    o = np.arange(-R, R + 1)
    dy, dx = np.meshgrid(o, o, indexing="ij")
    u = dx * ax + dy * ay
    v = dx * px + dy * py
    tip = min(w * 1.7, L * 0.5)
    half = np.where(u < L - tip, w, w * (L - u) / tip)
    inside = (u >= -1.5) & (u <= L) & (np.abs(v) <= half + 0.35)
    if not inside.any():
        return
    sgn = np.sign(v + 1e-6)
    s = np.abs(v) / np.maximum(half, 0.6)
    in_tip = u > L - tip
    face = np.where(in_tip, np.where(v < 0, 3, 4), np.where(s < 0.36, 1, np.where(v < 0, 0, 2)))
    lit = np.array([-0.6, -0.8])                 # towards the light, image coords
    side = sgn * (py * lit[0] + px * lit[1])     # +1 = this half faces the light
    litside = side > 0
    tone = np.where(face == 1, 4.4, np.where(litside, 6.2, 2.6))
    tone = np.where(in_tip, np.where(litside, 7.3, 4.4), tone)
    # outline all round (so overlapping crystals stay separate), pale on the lit edge;
    # a bright ridge where the lit face meets the middle face and along the tip
    fpad = np.where(inside, face, -1)
    nbr = [np.roll(fpad, k, ax) for k in (1, -1) for ax in (0, 1)]
    outer = inside & np.any([n < 0 for n in nbr], axis=0)
    ridge = inside & ~outer & litside & np.any([(n >= 0) & (n != fpad) for n in nbr], axis=0)
    tone = np.where(ridge, 8, tone)
    tone = np.where(outer, np.where(litside & (u > 1), 6.8, 0), tone)
    streak = inside & ~outer & (face == 1) & (np.abs(v) < 0.6) & (u > L * 0.25) & (u < L - tip) & \
        ((u.astype(int) % 6) < 2)
    tone = np.where(streak, tone + 1.5, tone)
    ti = np.clip(np.round(tone), 0, len(pal) - 1).astype(int)
    ys, xs = (cy + dy[inside]) % S, (cx + dx[inside]) % S
    img[ys, xs] = pal[ti[inside]]
    hh = 1.0 + 0.45 * (1 - np.clip((s - 0.36) / 0.64, 0, 1))
    hh = np.where(in_tip, hh - 0.35 * (u - (L - tip)) / max(tip, 1), hh)
    height[ys, xs] = hh[inside]
    # glow only on the brightest bits: the lit ridge, the lit edge and the very tip
    gi = np.where(ridge, 0.75, 0.0)
    gi = np.where(outer & litside & (u > L * 0.45), 0.55, gi)
    gi = np.where(in_tip & litside & (u > L - tip * 0.6), 1.0, gi)
    gi = np.where(streak, np.maximum(gi, 0.5), gi)
    glow[ys, xs] = np.maximum(glow[ys, xs], (glow_col * gi[inside, None]))


def crystal(name, S, rng):
    """Crystal caverns: dark violet host rock with clusters of amethyst/quartz prisms and a
    couple of fractured geodes."""
    host = palette("#07050c", "#0c0814", "#110b1c", "#170f25", "#1d142f", "#251a3a", "#2e2146", "#382953")
    cpal = palette("#140a24", "#22113d", "#331a58", "#462474", "#5b3192", "#7443ad", "#905fc7",
                   "#b28ae0", "#d9c0f5")
    idx = voronoi(S, rng.random((14, 2)) * S, 1.0, ((fractal(S, 4, 3, rng) - 0.5) * 12,
                                                    (fractal(S, 4, 3, rng) - 0.5) * 12))
    gap = borders(idx)
    gap = chip_corners(gap, idx, rng, 10, S)
    d = dist_to(~gap, 6)
    height = np.clip(d / 2.5, 0, 1) ** 0.8
    rough = fractal(S, 10, 3, rng)
    height += (rough - 0.5) * 0.2
    face = rng.choice([3.6, 4.2, 4.8], idx.max() + 1)
    shade = face[idx] + baked_light(height, 2.4) * 4.5 + (rough - 0.5) * 1.2
    shade = np.where(gap, 0, shade)
    img = host[np.clip(np.round(shade), 0, len(host) - 1).astype(int)]
    glow = np.zeros((S, S, 3))
    # tiny crystal grains sprinkled in the host rock
    for _ in range(40):
        y, x = rng.integers(0, S, 2)
        if d[y, x] > 1.5:
            img[y, x] = cpal[rng.integers(4, 7)]
            img[(y + 1) % S, (x + 1) % S] = host[1]
    # geodes: chalcedony rind, a ring of crystal teeth pointing in, a dark hollow; cracked through
    for gy, gx, gr in ((34, 92, 11.0), (100, 28, 8.5)):
        ry, rx = gr * 0.8, gr
        o = np.arange(-int(gr) - 3, int(gr) + 4)
        dy, dx = np.meshgrid(o, o, indexing="ij")
        r = np.sqrt((dy / ry) ** 2 + (dx / rx) ** 2)
        a = np.arctan2(dy, dx)
        t = (a / (2 * np.pi) * 16) % 1.0
        t = (a / (2 * np.pi) * 11 + 0.3 * np.sin(a * 3)) % 1.0
        tooth = (r < 0.86) & ((0.86 - r) / 0.62 < 1 - np.abs(t - 0.5) * 2)
        ys, xs = (gy + dy) % S, (gx + dx) % S
        lit_in = np.cos(a - np.arctan2(0.8, 0.6))      # inner wall facing up-left = lower-right part
        col = np.zeros(dy.shape + (3,))
        col[:] = palette("#06030a")[0]
        tt = np.clip(np.round(4.2 + 2.5 * lit_in * (t - 0.5) * 2 + 1.5 * (0.86 - r) / 0.62), 2, 8).astype(int)
        col = np.where(tooth[..., None], cpal[tt], col)
        rind = (r >= 0.86) & (r <= 1.0)
        rc = palette("#4a4360", "#6d6587", "#8f88a8")
        col = np.where(rind[..., None], rc[np.where(r < 0.93, 1 + (lit_in > 0.3), 0)], col)
        edge = (r > 1.0) & (r <= 1.13)
        col = np.where(edge[..., None], host[0], col)
        m = r <= 1.13
        img[ys[m], xs[m]] = col[m]
        height[ys[m], xs[m]] = np.where(r[m] < 0.86, 0.25 + 0.4 * tooth[m], 0.9)
        g = tooth & (tt >= 7)
        glow[ys[g], xs[g]] = palette("#b98cff")[0] * (0.6 + 0.4 * (tt[g] == 8))[:, None]
        pts, _ = walk(rng, gy - gr * 1.6, gx - gr * 0.5, int(gr * 3.4), 1.2, 0.2)   # the fracture
        for py, px in pts:
            iy, ix = int(py) % S, int(px) % S
            img[iy, ix] = host[0]
            img[iy, (ix + 1) % S] = img[iy, (ix + 1) % S] * 0.6
            height[iy, ix] -= 0.4
    # crystal clusters: fans of prisms growing out of the rock
    gcol = palette("#c9a0ff")[0]
    for cy, cx, ang0, big in ((84, 76, -1.75, 1.0), (24, 30, -0.6, 0.7), (110, 118, -2.5, 0.8),
                              (50, 112, 2.3, 0.55)):
        n = int(rng.integers(4, 7))
        spec = sorted(((rng.uniform(14, 40) * big, ang0 + rng.normal(0, 0.42), rng.uniform(3.2, 6.5) * big ** 0.5,
                        rng.uniform(-4, 4), rng.uniform(-4, 4)) for _ in range(n)), key=lambda q: -q[0])
        for L, ang, w, oy, ox in spec:
            prism(img, height, glow, rng, int(cy + oy), int(cx + ox), ang, L, w, cpal, gcol)
        for _ in range(4):                       # small shards around the foot
            prism(img, height, glow, rng, int(cy + rng.uniform(-7, 7)), int(cx + rng.uniform(-7, 7)),
                  ang0 + rng.normal(0, 0.9), rng.uniform(4, 8), rng.uniform(1.2, 2.0), cpal, gcol)
    save(name, img, height, 2.4)
    save_glow(name, glow)


def magma(name, S, rng):
    """Magma layer: near-black basalt blocks, a web of hot cracks between them (some cooled),
    ash-grey crust on the blocks, a few glassy obsidian bands."""
    pal = palette("#040303", "#080606", "#0c0908", "#110d0b", "#16110e", "#1c1612", "#231b16", "#2b221b")
    ash = palette("#1d1b1a", "#272524", "#33302e", "#3f3b38", "#4c4743", "#5a5450")
    hot = palette("#3a0c05", "#7a1a0a", "#c43a12", "#f06d1c", "#ffa63a", "#ffd97a")
    seeds = rng.random((12, 2)) * S
    idx = voronoi(S, seeds, 1.0, ((fractal(S, 4, 3, rng) - 0.5) * 16, (fractal(S, 4, 3, rng) - 0.5) * 16))
    seam = borders(idx)
    # a few branch cracks splitting blocks
    ys, xs = np.nonzero(seam)
    for _ in range(6):
        i = rng.integers(len(ys))
        pts, _ = walk(rng, ys[i], xs[i], int(rng.integers(8, 20)), rng.uniform(0, 6.28), 0.15)
        for py, px in pts:
            seam[int(py) % S, int(px) % S] = True
    ds = dist_to(~seam, 8)                       # distance to the crack's core line
    wid = 0.6 + 2.0 * fractal(S, 6, 2, rng)      # crack half-width wanders 0.6..2.6 px
    crack = ds <= wid
    heatn = np.clip((fractal(S, 6, 2, rng) - 0.42) / 0.2, 0, 1)   # about half the cracks have cooled
    heat = heatn * np.clip(1 - ds / (wid + 0.6), 0, 1) ** 0.8
    heat = np.where(crack, heat, 0)
    d = np.maximum(ds - wid, 0)
    height = np.clip(d / 3.0, 0, 1) ** 0.7
    rough = fractal(S, 12, 3, rng)
    height += (rough - 0.5) * 0.2
    face = rng.choice([3.4, 4.0, 4.6], idx.max() + 1)
    shade = face[idx] + baked_light(height, 2.4) * 4.0 + (rough - 0.5) * 1.2
    img = pal[np.clip(np.round(shade), 0, len(pal) - 1).astype(int)]
    # ash crust patches with small pits
    crust = (fractal(S, 6, 3, rng) > 0.56) & (d > 2.5)
    at = np.clip(np.round(2.3 + baked_light(height, 2.4) * 4 + (rough - 0.5) * 2.5), 0, len(ash) - 1).astype(int)
    img = np.where(crust[..., None], ash[at], img)
    pits = crust & (rng.random((S, S)) < 0.05)
    img[pits] = ash[0]
    craze = borders(voronoi(S, rng.random((70, 2)) * S)) & crust     # crazing in the crust
    img[craze] = ash[0]
    img[np.roll(craze, 1, 0) & crust & ~craze] = ash[4]
    height = np.where(craze, height - 0.12, height)
    height = np.where(crust, height + 0.08, height)
    # obsidian: glassy black bands with a sharp cold highlight along their top edge
    yy, xx = np.mgrid[0:S, 0:S]
    off = rng.integers(-3, 4, idx.max() + 1)
    for c, hw in ((40, 2.6), (97, 1.8)):
        band_c = c + wave(S, 2, rng, 6.0)[xx] + off[idx]
        dyb = yy - band_c
        ob = (np.abs(dyb) < hw + wave(S, 8, rng, 0.8)[xx]) & ~crack & (d > 0.5)
        img[ob] = palette("#040407")[0]
        top_e = ob & ~np.roll(ob, 1, 0)
        img[top_e] = palette("#2b3140")[0]
        hl = ob & (np.abs(dyb + hw * 0.35) < 0.5) & (fractal(S, 10, 1, rng) > 0.5)   # glassy sheen
        img[hl] = palette("#4a5468")[0]
        img[hl & (rng.random((S, S)) < 0.12)] = palette("#9aa6bc")[0]
        img[ob & ~np.roll(ob, -1, 0)] = palette("#0e0f14")[0]
        height = np.where(ob, height + 0.1, height)
    # rock right at a hot crack is heat-tinted
    rim = ~crack & (ds <= wid + 1.5) & (heatn > 0.3)
    img = np.where(rim[..., None], img * 0.6 + hot[0] * 0.4 * heatn[..., None], img)
    # the cracks themselves: cooled ones are dark grooves, hot ones get hotter towards the core
    hi = np.clip(np.floor(heat * 6), 0, 5).astype(int)
    img = np.where(crack[..., None], np.where((heat > 0.04)[..., None], hot[hi], pal[0]), img)
    height = np.where(crack, -0.4 + 0.1 * heat, height)
    save(name, img, height, 2.4)
    glow = np.where((crack & (heat > 0.12))[..., None], hot[np.clip(hi, 1, 5)] * np.clip(heat * 1.3, 0.35, 1)[..., None], 0)
    save_glow(name, glow)


class Fold:
    """Wrapped vector drawing: draw on a 3x canvas around the tile, then fold it back so
    anything crossing an edge comes in on the other side."""

    def __init__(self, size):
        self.S = size
        self.img = Image.new("L", (size * 3, size * 3), 0)
        self.dr = ImageDraw.Draw(self.img)

    def line(self, pts, width=1):
        self.dr.line([(x + self.S, y + self.S) for x, y in pts], fill=255, width=width)

    def arc(self, cx, cy, r, a0=0, a1=360):
        self.dr.arc([cx - r + self.S, cy - r + self.S, cx + r + self.S, cy + r + self.S], a0, a1, fill=255)

    def point(self, x, y):
        self.dr.point((x + self.S, y + self.S), fill=255)

    def mask(self):
        a = np.array(self.img) > 127
        S = self.S
        return np.any([a[j * S:(j + 1) * S, i * S:(i + 1) * S] for j in range(3) for i in range(3)], axis=0)


def glyph(fd, x, y, rng, scale=4):
    """An angular glyph: a few strokes on a 3x4 lattice (straight and 45 degree), with a
    terminal dot or two. (x, y) = top-left."""
    pts = [(i, j) for i in range(3) for j in range(4)]
    cur = pts[rng.integers(len(pts))]
    drawn, want = set(), int(rng.integers(4, 7))
    while len(drawn) < want:
        nxt = [(cur[0] + dx, cur[1] + dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1)
               if (dx or dy) and 0 <= cur[0] + dx < 3 and 0 <= cur[1] + dy < 4]
        n = nxt[rng.integers(len(nxt))]
        if len(drawn) and rng.random() < 0.2:    # lift the chisel: start a new stroke
            cur = pts[rng.integers(len(pts))]
            continue
        drawn.add(frozenset((cur, n)))
        fd.line([(x + cur[0] * scale, y + cur[1] * scale), (x + n[0] * scale, y + n[1] * scale)])
        cur = n
    fd.point(x + cur[0] * scale, y + cur[1] * scale - 2)


def floor(name, S, rng):
    """The Floor: ancient, impossibly smooth near-black blue-grey stone in huge, precisely cut
    blocks, engraved with concentric rings and rows of angular glyphs (the glyphs glow)."""
    pal = palette("#040508", "#07080c", "#0a0c11", "#0e1016", "#12151c", "#171a23", "#1c202b",
                  "#232835", "#2c3242")
    yy, xx = np.mgrid[0:S, 0:S]
    # two courses of huge blocks, dead straight seams
    rows = [(0, 72, (20, 100)), (72, 128, (60, 124))]
    label = np.zeros((S, S), int)
    for r, (y0, y1, cuts) in enumerate(rows):
        inrow = (yy >= y0) & (yy < y1)
        b = ((xx - cuts[0]) % S >= (cuts[1] - cuts[0])).astype(int)
        label = np.where(inrow, r * 10 + b, label)
    seam = borders(label)
    d = dist_to(~seam, 6)
    height = np.clip(d / 2.0, 0, 1)              # crisp 2 px chamfer, then dead flat
    # polished faces: each block a slow diagonal sheen, almost no grain
    sheen = np.zeros((S, S))
    for r, (y0, y1, cuts) in enumerate(rows):
        for b, (x0, w) in enumerate(((cuts[0], cuts[1] - cuts[0]), (cuts[1], S - (cuts[1] - cuts[0])))):
            m = label == r * 10 + b
            u = ((xx - x0) % S) / w
            v = (yy - y0) / (y1 - y0)
            sheen = np.where(m, 0.9 * (1 - u) * 0.5 + 0.9 * (1 - v) * 0.5 + rng.uniform(-0.3, 0.3), sheen)
    grain = fractal(S, 16, 2, rng)
    rings = Fold(S)
    glyphs = Fold(S)
    # block A: a full ring sigil
    cx, cy = 60, 36
    for r in (31, 27, 19, 12, 6):
        rings.arc(cx, cy, r)
    for k in range(24):                          # radial ticks between the outer rings
        a = np.radians(k * 15)
        r0, r1 = (19, 27) if k % 2 == 0 else (21, 25)
        glyphs.line([(cx + r0 * np.cos(a), cy + r0 * np.sin(a)), (cx + r1 * np.cos(a), cy + r1 * np.sin(a))])
    for k in range(6):                           # angular marks inside
        a = np.radians(k * 60 + 30)
        glyphs.line([(cx + 7 * np.cos(a), cy + 7 * np.sin(a)), (cx + 11 * np.cos(a), cy + 11 * np.sin(a))])
    glyphs.line([(cx - 3, cy), (cx, cy - 3), (cx + 3, cy), (cx, cy + 3), (cx - 3, cy)])
    # block A2 (narrow): a column of glyphs between two engraved rules
    rings.line([(106, 6), (106, 66)])
    rings.line([(142, 6), (142, 66)])
    for k in range(4):
        glyph(glyphs, 120, 7 + k * 16, rng)
    # block B1: a band of glyphs framed by rules
    rings.line([(66, 86), (118, 86)])
    rings.line([(66, 110), (118, 110)])
    for k in range(4):
        glyph(glyphs, 70 + k * 12, 91, rng)
    rings.line([(66, 116), (118, 116)])
    # block B2 (wraps the seam): half a ring sigil rising from the course below
    for r in (24, 18, 11):
        rings.arc(156, 128, r, 180, 360)
    for k in range(7):
        a = np.radians(195 + k * 25)
        glyphs.line([(156 + 12 * np.cos(a), 128 + 12 * np.sin(a)), (156 + 17 * np.cos(a), 128 + 17 * np.sin(a))])
    rm, gm = rings.mask() & (d > 1.5), glyphs.mask() & (d > 1.5)
    groove = rm | gm
    height = np.where(groove, height - 0.45, height)
    shade = 3.6 + sheen + (grain - 0.5) * 0.2 + baked_light(height, 2.0) * 4.0
    shade = np.where(seam, 0, shade)
    lip = ~groove & (np.roll(groove, 1, 0) | np.roll(groove, 1, 1)) & ~seam   # lit far wall of a groove
    shade = np.where(groove, 1.2, shade)
    shade = np.where(lip, shade + 1.2, shade)
    img = pal[np.clip(np.round(shade), 0, len(pal) - 1).astype(int)]
    gcol = np.array([112.0, 104.0, 168.0])        # faint cold violet-white
    glow = np.where(gm[..., None], gcol, 0.0)
    glow = np.where((gm & np.roll(gm, 1, 0) & np.roll(gm, -1, 0))[..., None], gcol * 1.15, glow)
    save(name, img, height, 2.2)
    save_glow(name, glow)


def bubble(img, height, glow, rng, cy, cx, r, pal, gcol):
    """A gas bubble trapped in the ice: a dark pressure rim, a pale bright inside, a hot
    highlight on the lit side. Slightly dimpled in the height field."""
    S = img.shape[0]
    ry = r * rng.uniform(0.9, 1.5)
    R = int(np.ceil(max(r, ry))) + 2

    def inside(dy, dx):
        return (dx / (r + 0.4)) ** 2 + (dy / (ry + 0.4)) ** 2 <= 1.0
    ys, xs, dy, dx = stamp_mask(S, cy, cx, R, inside)
    if len(ys) == 0:
        return
    occ = np.zeros((S, S), bool)
    occ[ys, xs] = True
    rim = occ & ~(np.roll(occ, 1, 0) & np.roll(occ, -1, 0) & np.roll(occ, 1, 1) & np.roll(occ, -1, 1))
    inner = occ & ~rim
    tl = inner & (~np.roll(inner, 1, 0) | ~np.roll(inner, 1, 1))         # lit inner edge, top-left
    br = inner & (~np.roll(inner, -1, 0) | ~np.roll(inner, -1, 1)) & ~tl  # shaded inner edge
    img[occ] = pal[2]                                                    # dark pressure ring
    img[inner] = pal[8]
    img[tl] = pal[9]
    img[br] = pal[6]
    hi = tl & ~np.roll(tl, 1, 0) & ~np.roll(tl, 1, 1)
    img[hi] = pal[9]
    ring_tl = rim & (~np.roll(occ, 1, 0) | ~np.roll(occ, 1, 1))
    img[ring_tl] = pal[3]
    height[occ] = np.minimum(height[occ], 0.55)
    height[rim] -= 0.25
    core = inner
    glow[core] = np.maximum(glow[core], gcol * 0.5)
    glow[hi] = np.maximum(glow[hi], gcol * 0.9)


def ice(name, S, rng):
    """Frozen layer: pale cyan slabs of glacier ice split by deep blue cracks, cloudy frost
    patches, strings of trapped gas bubbles. The glow map is a faint cold light coming from
    inside: crack cores, bubbles and a few veins."""
    pal = palette("#0a1a2b", "#10283f", "#173955", "#20506f", "#2d6b8b", "#3f87a6", "#5ca6c2",
                  "#82c4d9", "#aee0ee", "#d9f4fa")
    yy, xx = np.mgrid[0:S, 0:S]
    idx = voronoi(S, rng.random((9, 2)) * S, 0.8, ((fractal(S, 4, 3, rng) - 0.5) * 14,
                                                   (fractal(S, 4, 3, rng) - 0.5) * 14))
    gap = borders(idx)
    gap = chip_corners(gap, idx, rng, 8, S)
    d = dist_to(~gap, 6)
    height = np.clip(d / 2.2, 0, 1) ** 0.8
    rough = fractal(S, 10, 3, rng)
    height += (rough - 0.5) * 0.14
    # slow diagonal sheen across each slab (whole cycles, so it wraps), warped by noise
    warp = (fractal(S, 5, 2, rng) - 0.5) * 2.5
    sheen = np.sin(2 * np.pi * (3 * xx / S + 2 * yy / S) + warp * 2)
    face = rng.choice([5.4, 6.0, 6.5], idx.max() + 1)
    cloud = fractal(S, 6, 3, rng)
    clear = fractal(S, 4, 2, rng)
    shade = face[idx] + baked_light(height, 2.4) * 4.2 + (rough - 0.5) * 1.4 + sheen * 0.45
    shade = np.where(cloud > 0.6, shade + 1.4, shade)                   # frosted, milky patches
    shade = np.where(clear < 0.36, shade - 1.3, shade)                  # clear deep ice
    shade = np.where(gap, 1.2, shade)
    lip = ~gap & (np.roll(gap, 1, 0) | np.roll(gap, 1, 1))              # lit far wall of a seam
    shade = np.where(lip, shade + 1.5, shade)
    img = pal[np.clip(np.round(shade), 0, len(pal) - 1).astype(int)]
    glow = np.zeros((S, S, 3))
    gcol = np.array([70.0, 190.0, 235.0])
    # fine cracks wandering through the slabs: dark groove, bright lit lip, faint light inside
    for _ in range(7):
        y, x = rng.uniform(0, S), rng.uniform(0, S)
        pts, _ = walk(rng, y, x, int(rng.integers(30, 80)), rng.uniform(0, 6.28), 0.28)
        for k, (py, px) in enumerate(pts):
            iy, ix = int(py) % S, int(px) % S
            img[iy, ix] = pal[0]
            height[iy, ix] -= 0.5
            below, right = (iy + 1) % S, (ix + 1) % S
            if not gap[below, ix]:
                img[below, ix] = pal[8]
            if not gap[iy, right] and k % 2 == 0:
                img[iy, right] = pal[7]
            glow[iy, ix] = np.maximum(glow[iy, ix], gcol * (0.32 + 0.2 * (k % 5 == 0)))
    # the seams between slabs are open crevasses: a thin cold light deep inside the long ones
    core = gap & np.roll(gap, 1, 0) & np.roll(gap, -1, 0) | gap & np.roll(gap, 1, 1) & np.roll(gap, -1, 1)
    glow = np.where(core[..., None], np.maximum(glow, gcol * 0.24), glow)
    # strings of bubbles that rose and froze in place: big at the bottom, thinning upward
    for _ in range(6):
        x, y = rng.uniform(0, S), rng.uniform(0, S)
        for k in range(int(rng.integers(3, 7))):
            r = max(0.8, rng.uniform(2.0, 3.2) - 0.35 * k)
            bubble(img, height, glow, rng, int(y) % S, int(x) % S, r, pal, gcol)
            y -= r * 2 + rng.uniform(2, 6)
            x += rng.uniform(-2.5, 2.5)
    for _ in range(26):                                                  # stray micro bubbles
        iy, ix = int(rng.integers(0, S)), int(rng.integers(0, S))
        if not gap[iy, ix]:
            img[iy, ix] = pal[9]
            img[(iy + 1) % S, (ix + 1) % S] = pal[2]
            glow[iy, ix] = gcol * 0.4
    # frost: tiny white ferns and dust along the seams, a few drifting in the faces
    ys, xs = np.nonzero(gap)
    for _ in range(46):
        i = rng.integers(len(ys))
        sy, sx = rng.choice([-1, 1]), rng.choice([-1, 1])
        for k in range(int(rng.integers(2, 6))):
            iy, ix = (ys[i] + sy * k) % S, (xs[i] + sx * (k + 1) // 2 * 2) % S
            if not gap[iy, ix]:
                img[iy, ix] = pal[9] if k % 2 == 0 else pal[8]
    for _ in range(70):
        iy, ix = int(rng.integers(0, S)), int(rng.integers(0, S))
        if not gap[iy, ix]:
            img[iy, ix] = pal[8]
    # faint inner veins: a few light-scattering streaks drawn diagonally across the clear ice
    for _ in range(4):
        y, x = rng.uniform(0, S), rng.uniform(0, S)
        pts, _ = walk(rng, y, x, int(rng.integers(14, 30)), -0.7 + rng.normal(0, 0.2), 0.08)
        for py, px in pts:
            iy, ix = int(py) % S, int(px) % S
            if not gap[iy, ix]:
                glow[iy, ix] = np.maximum(glow[iy, ix], gcol * 0.2)
    save(name, img, height, 2.4)
    save_glow(name, glow)


def mask(name, size, rng):
    """Tileable low-frequency noise used to cut holes in the back wall."""
    m = fractal(size, 4, 4, rng)
    m = (m - m.min()) / (m.max() - m.min())
    v = (m * 65535).astype(np.uint32)    # 16-bit precision split across R (high) and G (low)
    rgb = np.dstack([v >> 8, v & 255, np.zeros_like(v)]).astype(np.uint8)
    Image.fromarray(rgb, "RGB").save(os.path.join(OUT, name + ".png"))


if __name__ == "__main__":
    import sys
    only = sys.argv[1:]          # e.g. `gen_textures.py ice` regenerates just that material

    def want(n):
        return not only or n in only
    S = 128
    if want("dirt"):
        dirt("dirt", S, np.random.default_rng(1337))
    if want("stone"):
        stone("stone", S, np.random.default_rng(1338))
    if want("hard"):
        hard("hard", S, np.random.default_rng(1339))
    if want("bedrock"):
        bedrock("bedrock", S, np.random.default_rng(1340))
    if want("wall"):
        wall("wall", 256, np.random.default_rng(1341))
    if want("crystal"):
        crystal("crystal", S, np.random.default_rng(1342))
    if want("magma"):
        magma("magma", S, np.random.default_rng(1343))
    if want("floor"):
        floor("floor", S, np.random.default_rng(1344))
    if want("ice"):
        ice("ice", S, np.random.default_rng(1345))
    if want("wall_mask"):
        # the wall holes keep their old layout: this is the generator state the first version of
        # this script had reached by the time it made the mask
        rng = np.random.default_rng()
        rng.bit_generator.state = {"bit_generator": "PCG64", "state": {
            "state": 220857099274669642158752682641119722502, "inc": 57444059933479602987059412884031907751},
            "has_uint32": 1, "uinteger": 3763446967}
        mask("wall_mask", 512, rng)
