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
from PIL import Image

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


def mask(name, size, rng):
    """Tileable low-frequency noise used to cut holes in the back wall."""
    m = fractal(size, 4, 4, rng)
    m = (m - m.min()) / (m.max() - m.min())
    v = (m * 65535).astype(np.uint32)    # 16-bit precision split across R (high) and G (low)
    rgb = np.dstack([v >> 8, v & 255, np.zeros_like(v)]).astype(np.uint8)
    Image.fromarray(rgb, "RGB").save(os.path.join(OUT, name + ".png"))


if __name__ == "__main__":
    S = 128
    dirt("dirt", S, np.random.default_rng(1337))
    stone("stone", S, np.random.default_rng(1338))
    hard("hard", S, np.random.default_rng(1339))
    bedrock("bedrock", S, np.random.default_rng(1340))
    wall("wall", 256, np.random.default_rng(1341))
    # the wall holes keep their old layout: this is the generator state the first version of
    # this script had reached by the time it made the mask
    rng = np.random.default_rng()
    rng.bit_generator.state = {"bit_generator": "PCG64", "state": {
        "state": 220857099274669642158752682641119722502, "inc": 57444059933479602987059412884031907751},
        "has_uint32": 1, "uinteger": 3763446967}
    mask("wall_mask", 512, rng)
