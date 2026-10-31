#!/usr/bin/env python3
"""Generates the parallax background layers into assets/bg/.

Cave layers (512x512) tile in both directions: grey values + alpha, tinted per depth zone in
game, so all shading here is value only. Each is a "storey" of cave: a rock shelf that wraps
across the tile's top/bottom seam, stalactites hanging from it, stalagmites growing up to it,
columns and arches between, soft fog bands. Far = faint, foggy, old mine scaffolding and
chains; mid = arches and columns; near = big chunky dark formations.
Surface layers (1024x160) tile horizontally, bottom = horizon: misty ridges, hills with an
abandoned mine headframe, and a dead forest with undergrowth.
Run:  python3 tools/gen_backgrounds.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "bg")
os.makedirs(OUT, exist_ok=True)
NB8 = ((0, 1, 1.0), (0, -1, 1.0), (1, 0, 1.0), (-1, 0, 1.0),
       (1, 1, 1.414), (1, -1, 1.414), (-1, 1, 1.414), (-1, -1, 1.414))


# ---------------------------------------------------------------- noise (tileable)
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


def line1d(w, cells, octaves, rng):
    """Tileable 1-D noise of length w in [-1, 1]."""
    return (fractal(1, w, 1, cells, octaves, rng)[0] - 0.5) * 2


def dist_to(solid, maxd):
    """Chamfer distance from solid pixels to the nearest empty one (wraps both ways)."""
    d = np.where(solid, float(maxd), 0.0)
    for _ in range(maxd + 2):
        m = d
        for dy, dx, wt in NB8:
            m = np.minimum(m, np.roll(d, (dy, dx), (0, 1)) + wt)
        m = np.where(solid, np.minimum(m, maxd), 0.0)
        if np.array_equal(m, d):
            break
        d = m
    return d


# ---------------------------------------------------------------- wrapped drawing
class Canvas:
    """Draws everything 9 times (or 3 when only x wraps) so shapes cross the tile seams."""

    def __init__(self, w, h, wrap_y=True):
        self.w, self.h, self.wrap_y = w, h, wrap_y
        self.img = Image.new("L", (w, h), 0)
        self.dr = ImageDraw.Draw(self.img)

    def _offs(self):
        for oy in ((-self.h, 0, self.h) if self.wrap_y else (0,)):
            for ox in (-self.w, 0, self.w):
                yield ox, oy

    def poly(self, pts, fill=255):
        for ox, oy in self._offs():
            self.dr.polygon([(x + ox, y + oy) for x, y in pts], fill=fill)

    def line(self, pts, fill=255, width=1):
        for ox, oy in self._offs():
            self.dr.line([(x + ox, y + oy) for x, y in pts], fill=fill, width=width)

    def rect(self, x0, y0, x1, y1, fill=255):
        for ox, oy in self._offs():
            self.dr.rectangle([x0 + ox, y0 + oy, x1 + ox, y1 + oy], fill=fill)

    def ellipse(self, x0, y0, x1, y1, fill=None, outline=None, width=1):
        for ox, oy in self._offs():
            self.dr.ellipse([x0 + ox, y0 + oy, x1 + ox, y1 + oy], fill=fill, outline=outline, width=width)

    def point(self, x, y, fill=255):
        for ox, oy in self._offs():
            self.dr.point((x + ox, y + oy), fill=fill)

    def mask(self):
        return np.array(self.img) > 127

    def array(self):
        return np.array(self.img)


# ---------------------------------------------------------------- formation shapes
def spike_pts(x, y, length, width, rng, down=True, bend=0.0, blunt=0.0, steps=10):
    """Outline of a stalactite (down) or stalagmite (up): concave taper, wobbly sides, bent tip."""
    s = 1 if down else -1
    left, right = [], []
    p = 0.75 if down else 0.55
    for i in range(steps + 1):
        t = i / steps
        hw = width / 2 * max((1 - t) ** p, blunt) * (1 + rng.uniform(-0.12, 0.12))
        cx = x + bend * t * t
        yy = y + s * length * t
        left.append((cx - hw, yy))
        right.append((cx + hw, yy))
    base = [(x - width / 2 - 2, y - s * 4), (x + width / 2 + 2, y - s * 4)]
    return [base[0]] + left + right[::-1] + [base[1]]


def spike_cluster(cv, x, y, length, width, rng, down=True, extra=2):
    cv.poly(spike_pts(x, y, length, width, rng, down, rng.uniform(-0.15, 0.15) * length,
                      0.0 if down else rng.uniform(0.08, 0.18)))
    for _ in range(extra):
        dx = rng.uniform(-1.2, 1.2) * width
        L = length * rng.uniform(0.25, 0.65)
        cv.poly(spike_pts(x + dx, y, L, width * rng.uniform(0.35, 0.7), rng, down,
                          rng.uniform(-0.1, 0.1) * L, 0.0 if down else 0.15))


def column_pts(x, y0, y1, wtop, wmid, wbot, rng, steps=24):
    """A cave column (stalactite met stalagmite): wide ends, pinched waist with bulges."""
    left, right = [], []
    sway = rng.uniform(-6, 6)
    for i in range(steps + 1):
        t = i / steps
        a = abs(2 * t - 1) ** 1.6
        w = wmid + ((wtop if t < 0.5 else wbot) - wmid) * a
        w *= 1 + 0.12 * np.sin(t * 17 + x) + rng.uniform(-0.05, 0.05)
        cx = x + sway * np.sin(np.pi * t)
        yy = y0 + (y1 - y0) * t
        left.append((cx - w / 2, yy))
        right.append((cx + w / 2, yy))
    return left + right[::-1]


def shelf(w, h, centre, thick, rng, cells=6, gaps=0.0):
    """Mask of a horizontal rock shelf crossing the tile at `centre` (may wrap the y seam).
    `gaps` > 0 breaks it into separate masses. Returns mask, top and bottom edge per column
    (unwrapped y; where there's a gap top == bottom == centre)."""
    n1, n2, n3 = line1d(w, cells, 3, rng), line1d(w, cells, 3, rng), line1d(w, 3, 3, rng)
    th = thick * (1 + 0.4 * n3)
    if gaps:
        th = th * np.clip((n3 + 1 - 2 * gaps) * 4, 0, 1)
    top = centre - th / 2 + n1 * th * 0.3
    bot = centre + th / 2 + n2 * th * 0.25
    yy = np.arange(h)[:, None]
    m = np.zeros((h, w), bool)
    for k in (-1, 0, 1):
        m |= (yy + k * h >= top[None, :]) & (yy + k * h <= bot[None, :])
    m &= (bot - top)[None, :] > 1.5
    return m, top, bot


def place(rng, S, centres, n, spread):
    """x positions bunched around a few centres (formations come in groups, not evenly)."""
    c = np.array(centres)[rng.integers(0, len(centres), n)]
    return (c + rng.normal(0, spread, n)) % S


# ---------------------------------------------------------------- value shading
def shade_rock(mask, rng, base, rim, inner, maxd=14, steps=24):
    """Value for a rock silhouette, painted in a few bands: lit top rim, softer side rims,
    a dark underside lip, and darker towards the core (volume). Quantized to pixel-art steps."""
    h, w = mask.shape
    d = dist_to(mask, maxd)
    v = base - inner * np.clip((d - 2) / maxd, 0, 1) ** 0.7
    v += (fractal(h, w, 4, 4, 3, rng) - 0.5) * 0.06          # large, calm variation
    up1, up2 = np.roll(mask, 1, 0), np.roll(mask, 2, 0)
    top = mask & (~up1 | ~up2)
    side = mask & (~np.roll(mask, 1, 1) | ~np.roll(mask, -1, 1)) & ~top
    under = mask & ~np.roll(mask, -1, 0) & ~top
    v = np.where(side, (v + rim) / 2, v)
    v = np.where(under, v - inner * 0.4, v)
    v = np.where(top, rim, v)
    return np.round(v * steps) / steps


def fog_band(h, w, centres, width, rng, wisp=0.5):
    """Soft horizontal fog (0..1), periodic in y, wispy in x."""
    yy = np.arange(h)[:, None].astype(float)
    n = fractal(h, w, 4, 8, 3, rng)
    f = np.zeros((h, w))
    for c in centres:
        dy = (yy - c + h / 2) % h - h / 2
        dy = dy + (n - 0.5) * width * 1.4
        f = np.maximum(f, np.exp(-(dy / width) ** 2))
    f *= 1 - wisp + wisp * fractal(h, w, 2, 6, 2, rng)
    return np.clip(f, 0, 1)


def to_rgba(value, alpha):
    g = (np.clip(value, 0, 1) * 255).astype(np.uint8)
    a = (np.clip(alpha, 0, 1) * 255).astype(np.uint8)
    return Image.fromarray(np.dstack([g, g, g, a]), "RGBA")


def steps(a, levels=10):
    """Quantize a soft alpha into flat bands (painted fog rather than a smooth gradient)."""
    return np.round(a * levels) / levels


# ---------------------------------------------------------------- mine props (far layer)
def chain(cv, x, y, length, fill):
    for k in range(int(length)):
        if (k // 2) % 2 == 0:
            cv.point(x, y + k, fill)
        else:
            cv.point(x - 1, y + k, fill)
            cv.point(x + 1, y + k, fill)


def scaffold(cv, x, ground, height, width, rng, fill):
    """Old timber mine supports: posts, cap beams, braces, a landing and a ladder."""
    posts = np.linspace(x, x + width, int(width // 22) + 2)
    levels = [ground - height * f for f in (0.5, 1.0)]
    for i, px in enumerate(posts):
        top = levels[1] if i not in (0, len(posts) - 1) or rng.random() < 0.7 else levels[0]
        cv.rect(px - 1, top, px + 1, ground + 3, fill)
    for ly in levels:
        cv.rect(posts[0] - 4, ly - 1, posts[-1] + 4, ly + 1, fill)
        for k in range(int(posts[0] - 3), int(posts[-1] + 3), 5):      # plank ends
            cv.point(k, ly - 2, fill)
    for a, b in zip(posts[:-1], posts[1:]):
        lo, hi = ground, levels[0]
        if rng.random() < 0.8:
            cv.line([(a, lo), (b, hi)], fill)
        if rng.random() < 0.6:
            cv.line([(a, hi), (b, levels[1])], fill)
    # a broken plank hanging off one end
    cv.line([(posts[-1] + 4, levels[0]), (posts[-1] + 12, levels[0] + 9)], fill, 2)
    lx = posts[int(rng.integers(0, len(posts) - 1))] + 6     # ladder
    cv.line([(lx, ground), (lx, levels[1] - 6)], fill)
    cv.line([(lx + 5, ground), (lx + 5, levels[1] - 6)], fill)
    for ry in range(int(levels[1] - 4), int(ground), 4):
        cv.line([(lx, ry), (lx + 5, ry)], fill)
    return posts, levels


def headframe_small(cv, x, ground, hgt, fill):
    """A little winding tower with its sheave wheel (seen in the far cave)."""
    cv.line([(x - hgt * 0.28, ground), (x, ground - hgt)], fill, 2)
    cv.line([(x + hgt * 0.28, ground), (x, ground - hgt)], fill, 2)
    cv.line([(x + hgt * 0.6, ground), (x + 1, ground - hgt * 0.9)], fill, 1)
    for f in (0.3, 0.6):
        y = ground - hgt * f
        hw = hgt * 0.28 * (1 - f)
        cv.line([(x - hw, y), (x + hw, y)], fill)
    cv.ellipse(x - 5, ground - hgt - 5, x + 5, ground - hgt + 5, outline=fill, width=1)
    cv.line([(x - 5, ground - hgt), (x + 5, ground - hgt)], fill)
    cv.line([(x, ground - hgt - 5), (x, ground - hgt + 5)], fill)
    chain(cv, x + 5, ground - hgt, hgt * 0.7, fill)


# ---------------------------------------------------------------- cave layers
def arch(S, cx, floor, span, rise, thick, rng):
    """Mask of a natural rock arch standing on the floor (legs + rounded opening)."""
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    wy = (fractal(S, S, 8, 8, 2, rng) - 0.5) * 10
    wx = (fractal(S, S, 8, 8, 2, rng) - 0.5) * 10
    dx = (xx + wx - cx + S / 2) % S - S / 2
    dy = yy + wy - floor
    outer = (dx / (span / 2 + thick)) ** 2 + (dy / (rise + thick * 0.8)) ** 2 <= 1
    inner = (dx / (span / 2)) ** 2 + (dy / rise) ** 2 <= 1
    return outer & ~inner & (dy <= 0)


def cave_far(name, S, rng):
    """Faint and foggy: a thin ceiling/floor shelf, drapery, one distant column,
    old mine scaffolding and a headframe on the floor, chains hanging from the roof."""
    sh, top, bot = shelf(S, S, 474, 30, rng, cells=8)
    rock = Canvas(S, S)
    rock.img = Image.fromarray(np.where(sh, 255, 0).astype(np.uint8), "L")
    rock.dr = ImageDraw.Draw(rock.img)
    ceil = lambda x: bot[int(x) % S] - S - 2       # roof of this storey (top of the tile)
    floor = lambda x: top[int(x) % S] + 2
    groups = rng.uniform(0, S, 3)
    for x in place(rng, S, groups, 22, 40):          # stalactites, bunched
        spike_cluster(rock, x, ceil(x), rng.uniform(14, 60), rng.uniform(5, 12), rng, True,
                      int(rng.integers(0, 3)))
    for x in place(rng, S, groups[:2], 3, 30):       # big flowstone draperies
        for k in range(5):
            spike_cluster(rock, x + (k - 2) * 9, ceil(x), rng.uniform(50, 110) * (1 - abs(k - 2) * 0.2),
                          rng.uniform(14, 22), rng, True, 0)
    for x in place(rng, S, [groups[2] + 160], 8, 60):
        spike_cluster(rock, x, floor(x), rng.uniform(10, 34), rng.uniform(8, 16), rng, False, 1)
    mx = (groups[0] + 250) % S                       # a small distant arch on the floor
    am = arch(S, mx, floor(mx) + 3, 96, 84, 15, rng)
    rock.img = Image.fromarray(np.maximum(np.array(rock.img), np.where(am, 255, 0)).astype(np.uint8), "L")
    rock.dr = ImageDraw.Draw(rock.img)
    x = (groups[1] + 180) % S                        # one distant column
    rock.poly(column_pts(x, ceil(x) - 2, floor(x) + 2, 46, 12, 54, rng))
    m = rock.mask()
    fog = fog_band(S, S, [440, 200], 34, rng) * 0.8
    v = shade_rock(m, rng, 0.86, 0.98, 0.14)
    v = v + (1 - v) * fog * 0.7

    wood = Canvas(S, S)                              # mine timbers + chains, crisp and darker
    sx = (mx + 120) % S
    scaffold(wood, sx, floor(sx) - 1, 70, 92, rng, 255)
    sx2 = (sx + 240) % S
    scaffold(wood, sx2, floor(sx2) - 1, 40, 44, rng, 255)
    hx = (sx + 150) % S
    headframe_small(wood, hx, floor(hx), 56, 255)
    for k in range(int(sx - 40), int(sx + 200)):     # rail with ties along the floor
        if k % 2 == 0:
            wood.point(k % S, top[k % S] - 1)
        if k % 6 == 0:
            wood.point(k % S, top[k % S] - 2)
    for x in place(rng, S, groups, 7, 70):           # chains from the roof
        x = int(x)
        L = rng.uniform(25, 130)
        chain(wood, x, ceil(x) + 1, L, 255)
        if rng.random() < 0.5:                       # hook or a little cage
            wood.rect(x - 2, ceil(x) + 1 + L, x + 2, ceil(x) + 5 + L, 255)
    x0 = groups[1] - 40                              # a chain slung between two anchors
    for t in np.linspace(0, 1, 90):
        xx = x0 + 70 * t
        wood.point(xx, ceil(x0) + 6 + 26 * 4 * t * (1 - t) + (int(xx) % 3 == 0), 255)
    wm = wood.mask() & ~(m & (fog < 0.01) & ~np.roll(m, 1, 0))
    v = np.where(wm, 0.62 + fog * 0.25, v)
    alpha = np.where(m | wm, 1.0, steps(0.14 + fog * 0.36, 16))   # faint haze everywhere
    v = np.where(m | wm, v, 1.0)
    to_rgba(v, alpha).save(os.path.join(OUT, name + ".png"))
    print("wrote", name, f"{(m | wm).mean():.0%} solid")


def cave_mid(name, S, rng):
    """A natural arch, a column, stalactite curtains and stalagmites, a fog band low down."""
    sh, top, bot = shelf(S, S, 14, 44, rng, cells=6)
    rock = Canvas(S, S)
    ceil = lambda x: bot[int(x) % S] - 2
    floor = lambda x: top[int(x) % S] + S + 2
    ax = rng.uniform(0, S)
    am = arch(S, ax, floor(ax) + 4, rng.uniform(190, 230), rng.uniform(220, 260), 46, rng)
    rock.img = Image.fromarray(np.where(sh | am, 255, 0).astype(np.uint8), "L")
    rock.dr = ImageDraw.Draw(rock.img)
    for i in range(10):                              # drips under the arch's opening
        x = ax + rng.uniform(-80, 80)
        col = am[:, int(x) % S]
        ys = np.nonzero(col)[0]
        if len(ys):
            under = ys[ys < floor(x) - 60].max(initial=-1)
            if under > 0:
                rock.poly(spike_pts(x, under - 2, rng.uniform(8, 34), rng.uniform(5, 10), rng, True))
    cx = (ax + S / 2 + rng.uniform(-30, 30)) % S
    rock.poly(column_pts(cx, ceil(cx) - 4, floor(cx) + 4, 74, 20, 84, rng))
    groups = [(ax + 150) % S, (cx + 90) % S, (cx - 80) % S]
    for x in place(rng, S, groups, 18, 35):
        spike_cluster(rock, x, ceil(x), rng.uniform(20, 95), rng.uniform(9, 20), rng, True,
                      int(rng.integers(1, 3)))
    for x in place(rng, S, groups[1:], 9, 40):
        spike_cluster(rock, x, floor(x), rng.uniform(16, 70), rng.uniform(12, 26), rng, False, 1)
    for x in place(rng, S, [ax], 6, 60):             # rubble at the arch's feet
        r = rng.uniform(3, 8)
        y = floor(x) - 2
        rock.ellipse(x - r * 1.4, y - r, x + r * 1.4, y + r, fill=255)
    m = rock.mask()
    fog = fog_band(S, S, [430], 34, rng, 0.6)
    v = shade_rock(m, rng, 0.76, 0.94, 0.2, maxd=16)
    v = v + (1 - v) * fog * 0.5
    alpha = np.where(m, 1.0, steps(fog * 0.22, 16))
    v = np.where(m, v, 1.0)
    to_rgba(v, alpha).save(os.path.join(OUT, name + ".png"))
    print("wrote", name, f"{m.mean():.0%} solid")


def cave_near(name, S, rng):
    """Big chunky dark formations: broken rock ledges with fat stalactite curtains under them,
    blunt stalagmites and boulders on top."""
    sh, top, bot = shelf(S, S, 250, 78, rng, cells=4, gaps=0.18)
    rock = Canvas(S, S)
    rock.img = Image.fromarray(np.where(sh, 255, 0).astype(np.uint8), "L")
    rock.dr = ImageDraw.Draw(rock.img)
    solid = (bot - top) > 20
    xs = np.nonzero(solid)[0]
    for x in xs[rng.integers(0, len(xs), 9)]:
        spike_cluster(rock, x + rng.uniform(-4, 4), bot[x] - 4, rng.uniform(50, 130), rng.uniform(26, 46), rng,
                      True, 2)
    for x in xs[rng.integers(0, len(xs), 5)]:
        rock.poly(spike_pts(x, top[x] + 4, rng.uniform(30, 70), rng.uniform(34, 56), rng, False,
                            rng.uniform(-8, 8), rng.uniform(0.25, 0.4), 6))
        rock.poly(spike_pts(x + rng.uniform(14, 26), top[x] + 4, rng.uniform(15, 35), rng.uniform(18, 28), rng,
                            False, 0, 0.35, 5))
        r = rng.uniform(7, 13)                       # a boulder resting nearby
        bx = x + rng.choice([-1, 1]) * rng.uniform(25, 45)
        if solid[int(bx) % S]:
            y = top[int(bx) % S] + 4
            rock.ellipse(bx - r * 1.3, y - r * 1.5, bx + r * 1.3, y + r * 0.5, fill=255)
    m = rock.mask()
    v = shade_rock(m, rng, 0.66, 0.88, 0.22, maxd=22)
    to_rgba(np.where(m, v, 1.0), m.astype(float)).save(os.path.join(OUT, name + ".png"))
    print("wrote", name, f"{m.mean():.0%} solid")


# ---------------------------------------------------------------- surface layers
def shade_flat(mask, base, rim, n=None, tex=0.0):
    """Surface silhouettes: flat value, lit top rim, half-lit left edge."""
    v = np.full(mask.shape, base, float)
    if n is not None:
        v += (n - 0.5) * tex
    up, up2 = np.roll(mask, 1, 0), np.roll(mask, 2, 0)
    top = mask & (~up | ~up2)
    top[:2] &= False
    left = mask & ~np.roll(mask, 1, 1)
    v = np.where(left & ~top, (v + rim) / 2, v)
    return np.where(top, rim, v)


def ridge_mask(w, h, base_y, amp, cells, rng, sharp=0.0):
    n = line1d(w, cells, 4, rng)
    if sharp:
        n = np.sign(n) * np.abs(n) ** (1 - sharp)
    tops = base_y - n * amp
    return np.arange(h)[:, None] >= tops[None, :], tops


def hills_far(name, W, H, rng):
    back, tb = ridge_mask(W, H, 78, 42, 3, rng)
    front, tf = ridge_mask(W, H, 108, 30, 6, rng, 0.3)
    n = fractal(H, W, 8, 32, 3, rng)
    v = np.where(front, shade_flat(front, 0.82, 0.9, n, 0.05), shade_flat(back, 0.95, 1.0, n, 0.04))
    yy = np.arange(H)[:, None]
    # valley mist: the lower part of each ridge fades out into the sky
    a_back = np.clip(1.0 - (yy - tb[None, :]) / 70.0, 0.45, 1.0)
    a_front = np.clip(1.0 - (yy - tf[None, :]) / 50.0, 0.55, 1.0)
    alpha = np.where(front, np.maximum(a_front, 0.0), np.where(back, a_back * 0.85, 0.0))
    # tiny dead trees along the far ridge line
    cv = Canvas(W, H, wrap_y=False)
    for x in rng.uniform(0, W, 60):
        t = tb[int(x)]
        hgt = rng.uniform(3, 8)
        cv.line([(x, t + 1), (x, t - hgt)], 255)
        cv.point(x + rng.choice([-1, 1]), t - hgt * 0.6)
    tm = cv.mask() & ~front
    v = np.where(tm, 0.9, v)
    alpha = np.where(tm, 0.85, alpha)
    to_rgba(v, steps(alpha, 8)).save(os.path.join(OUT, name + ".png"))
    print("wrote", name)


def headframe(cv, x, ground, hgt, fill=255):
    """An abandoned mine headframe: A-frame legs, cross bracing, backstay, sheave wheel, shed."""
    top = ground - hgt
    lw, tw = hgt * 0.32, 3
    cv.poly([(x - lw, ground), (x - lw + 3, ground), (x - tw + 1, top), (x - tw, top)], fill)
    cv.poly([(x + lw, ground), (x + lw - 3, ground), (x + tw - 1, top), (x + tw, top)], fill)
    ys = np.linspace(ground, top, 6)
    for a, b in zip(ys[:-1], ys[1:]):
        wa = lw - (lw - tw) * (ground - a) / hgt
        wb = lw - (lw - tw) * (ground - b) / hgt
        cv.line([(x - wa, a), (x + wb, b)], fill)
        cv.line([(x + wa, a), (x - wb, b)], fill)
        cv.line([(x - wb, b), (x + wb, b)], fill)
    cv.line([(x + hgt * 0.75, ground), (x + 2, top + 4)], fill, 2)   # backstay
    cv.line([(x + hgt * 0.45, ground), (x + hgt * 0.38, ground - hgt * 0.45), (x + 2, top + 10)], fill)
    r = hgt * 0.13
    cv.ellipse(x - r, top - r - 2, x + r, top + r - 2, outline=fill, width=2)
    for a in np.linspace(0, np.pi, 4, endpoint=False):
        cv.line([(x - r * np.cos(a), top - 2 - r * np.sin(a)), (x + r * np.cos(a), top - 2 + r * np.sin(a))], fill)
    cv.rect(x - tw - 2, top - 2, x + tw + 2, top + 1, fill)
    cv.line([(x + r, top - 2), (x + hgt * 0.9, ground - 4)], fill)   # cable to the winding house
    # winding house: a shed with a sagging roof and a broken chimney
    sx = x + hgt * 0.8
    cv.poly([(sx, ground), (sx, ground - 12), (sx + 10, ground - 19), (sx + 24, ground - 13),
             (sx + 26, ground - 12), (sx + 26, ground)], fill)
    cv.rect(sx + 18, ground - 26, sx + 21, ground - 14, fill)
    cv.point(sx + 21, ground - 27, fill)


def hills_near(name, W, H, rng):
    m, tops = ridge_mask(W, H, 128, 34, 5, rng)
    cv = Canvas(W, H, wrap_y=False)
    # headframe on a rise, telegraph poles marching along the hills, a few small dead trees
    hx = int(np.argmin(tops[100:400])) + 100
    headframe(cv, hx, tops[hx] + 3, 64)
    poles = np.arange(hx + 140, hx + 140 + 7 * 64, 64) % W
    wire = []
    for px in poles:
        t = tops[int(px)] + 2
        cv.line([(px, t), (px + rng.uniform(-1.5, 1.5), t - 22)], 255, 2)
        cv.line([(px - 4, t - 19), (px + 4, t - 19)], 255)
        wire.append((px, t - 19))
    for (x0, y0), (x1, y1) in zip(wire[:-1], wire[1:]):
        if x1 < x0:
            x1 += W
        pts = [(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t + 7 * 4 * t * (1 - t)) for t in np.linspace(0, 1, 30)]
        cv.line(pts, 255)
    for x in rng.uniform(0, W, 22):
        t = tops[int(x)] + 2
        hgt = rng.uniform(8, 18)
        cv.line([(x, t), (x + rng.uniform(-2, 2), t - hgt)], 255, 1 + (hgt > 13))
        for k in range(2):
            by = t - hgt * rng.uniform(0.45, 0.85)
            s = rng.choice([-1, 1])
            cv.line([(x, by), (x + s * hgt * 0.3, by - hgt * 0.25)], 255)
    sm = cv.mask() & ~m
    n = fractal(H, W, 8, 32, 3, rng)
    v = shade_flat(m, 0.72, 0.84, n, 0.06)
    v = np.where(sm, 0.62, v)
    yy = np.arange(H)[:, None]
    alpha = np.where(m, np.clip(1.0 - (yy - tops[None, :]) / 80.0, 0.7, 1.0), 0.0)
    alpha = np.where(sm, 1.0, alpha)
    to_rgba(v, steps(alpha, 8)).save(os.path.join(OUT, name + ".png"))
    print("wrote", name)


def dead_forest(name, W, H, rng):
    yy = np.arange(H)[:, None]
    gnoise = line1d(W, 12, 3, rng)
    ground = (H - 11 + gnoise * 3).astype(int)
    back = Canvas(W, H, wrap_y=False)
    front = Canvas(W, H, wrap_y=False)

    def branch(cv, x, y, ang, length, width, depth, droop=0.0):
        if depth == 0 or length < 2.5:
            return
        x2 = x + np.cos(ang) * length
        y2 = y - np.sin(ang) * length
        cv.line([(x, y), (x2, y2)], 255, max(1, int(round(width))))
        kids = 2 if depth > 1 and rng.random() < 0.85 else 1
        for _ in range(kids):
            na = ang + rng.uniform(-0.75, 0.75) - droop
            branch(cv, x2, y2, na, length * rng.uniform(0.55, 0.78), width * 0.62, depth - 1, droop)

    def gnarled(cv, x, g, scale):
        hgt = rng.uniform(55, 100) * scale
        lean = rng.uniform(-0.18, 0.18)
        # twisted trunk: a few kinked segments, then a crown of branches
        px, py, w = x, g, rng.uniform(4, 6.5) * scale
        segs = int(rng.integers(2, 4))
        for i in range(segs):
            nx = px + np.sin(lean) * hgt * 0.45 / segs + rng.uniform(-2, 2)
            ny = py - hgt * 0.45 / segs
            cv.line([(px, py), (nx, ny)], 255, max(1, int(w)))
            if rng.random() < 0.5:
                branch(cv, nx, ny, np.pi / 2 + rng.choice([-1, 1]) * rng.uniform(0.7, 1.2),
                       hgt * 0.22, w * 0.5, 3, 0.1)
            px, py, w = nx, ny, w * 0.85
        for _ in range(int(rng.integers(2, 4))):
            branch(cv, px, py, np.pi / 2 + lean + rng.uniform(-0.6, 0.6), hgt * 0.32, w * 0.7, 5, 0.04)
        cv.poly([(x - w * 1.3, g + 2), (x, g - 5 * scale), (x + w * 1.3, g + 2)])   # root flare

    def snag(cv, x, g, scale):
        """Dead conifer: tall thin trunk, drooping stubs, broken top."""
        hgt = rng.uniform(70, 125) * scale
        w = rng.uniform(2.5, 4) * scale
        cv.poly([(x - w, g), (x + w, g), (x + 0.6, g - hgt), (x - 0.6, g - hgt + rng.uniform(0, 6))])
        y = g - hgt * 0.25
        side = 1
        while y > g - hgt + 4:
            L = (y - (g - hgt)) * rng.uniform(0.18, 0.32)
            cv.line([(x, y), (x + side * L, y + L * rng.uniform(0.2, 0.55))], 255)
            if rng.random() < 0.4:
                cv.line([(x, y - 2), (x - side * L * 0.6, y + L * 0.3)], 255)
            y -= rng.uniform(4, 8) * scale
            side = -side

    def broken(cv, x, g, scale):
        """Thick trunk snapped off with a jagged top, one surviving limb."""
        hgt = rng.uniform(22, 45) * scale
        w = rng.uniform(3.5, 5.5) * scale
        tw = w * 0.7
        pts = [(x - w - 2, g + 1), (x - w, g - 4)]
        for k in range(5):                           # splintered top: alternating spikes and notches
            up = rng.uniform(4, 12) * scale if k % 2 == 0 else -rng.uniform(0, 3) * scale
            pts.append((x - tw + 2 * tw * k / 4, g - hgt - up))
        pts += [(x + w, g - 4), (x + w + 2, g + 1)]
        cv.poly(pts)
        if rng.random() < 0.8:
            branch(cv, x + w * 0.5, g - hgt * 0.6, np.pi / 2 - rng.uniform(0.4, 0.9), hgt * 0.5, w * 0.45, 3)

    kinds = [gnarled, gnarled, snag, snag, broken]
    for x in np.sort(rng.uniform(0, W, 30)):                       # back row: smaller, hazier
        rng.choice(kinds)(back, x, ground[int(x)] - 2, 0.65)
    xs = np.sort(rng.uniform(0, W, 22))
    for x in xs:                                                   # front row
        rng.choice(kinds)(front, x, ground[int(x)], 1.0)
    # undergrowth: thorny scrub, grass tufts, a fallen log, a crooked fence and a grave cross
    for x in rng.uniform(0, W, 70):
        g = ground[int(x)]
        for _ in range(int(rng.integers(3, 7))):
            a = np.pi / 2 + rng.uniform(-1.0, 1.0)
            L = rng.uniform(4, 13)
            x2, y2 = x + np.cos(a) * L, g - np.sin(a) * L
            front.line([(x, g), (x2, y2)], 255)
            if L > 7:
                front.line([(x2, y2), (x2 + rng.uniform(-3, 3), y2 - rng.uniform(1, 3))], 255)
    for x in range(W):
        if rng.random() < 0.35:
            front.line([(x, ground[x]), (x + rng.choice([-1, 0, 1]), ground[x] - rng.integers(1, 6))], 255)
    lx = rng.uniform(0, W)
    front.poly([(lx, ground[int(lx)] - 1), (lx + 46, ground[int(lx + 46) % W] - 2),
                (lx + 46, ground[int(lx + 46) % W] - 7), (lx, ground[int(lx)] - 6)])
    front.line([(lx + 30, ground[int(lx + 30) % W] - 6), (lx + 36, ground[int(lx + 30) % W] - 14)], 255)
    fx = rng.uniform(0, W)
    for k in range(6):                                             # fence
        px = fx + k * 9
        g = ground[int(px) % W]
        front.line([(px, g), (px + rng.uniform(-1.5, 1.5), g - rng.uniform(8, 13))], 255, 2)
    front.line([(fx, ground[int(fx) % W] - 7), (fx + 30, ground[int(fx + 30) % W] - 9)], 255)
    front.line([(fx + 27, ground[int(fx + 27) % W] - 4), (fx + 45, ground[int(fx + 45) % W] - 7)], 255)
    cx = (fx + 80) % W                                             # a lone grave cross, leaning
    g = ground[int(cx)]
    front.line([(cx, g), (cx + 2, g - 15)], 255, 2)
    front.line([(cx - 4, g - 11), (cx + 6, g - 10)], 255, 2)
    gm = yy >= ground[None, :]
    fm = front.mask() | gm
    bm = back.mask() & ~fm
    n = fractal(H, W, 6, 40, 2, rng)
    v = np.where(fm, shade_flat(fm, 0.48, 0.6, n, 0.04), shade_flat(bm, 0.74, 0.8))
    alpha = np.where(fm, 1.0, np.where(bm, 0.9, 0.0))
    to_rgba(v, alpha).save(os.path.join(OUT, name + ".png"))
    print("wrote", name)


if __name__ == "__main__":
    # far -> near. Brighter value = more fog (tinted per depth in game)
    cave_far("cave_far", 512, np.random.default_rng(2024))
    cave_mid("cave_mid", 512, np.random.default_rng(2025))
    cave_near("cave_near", 512, np.random.default_rng(2026))
    hills_far("hills_far", 1024, 160, np.random.default_rng(2027))
    hills_near("hills_near", 1024, 160, np.random.default_rng(2028))
    dead_forest("forest", 1024, 160, np.random.default_rng(2029))
