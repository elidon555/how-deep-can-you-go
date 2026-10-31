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


def walk(rng, y, x, steps, ang, turn):
    """A wandering path of (y, x) points, 1 px per step."""
    pts = []
    for _ in range(steps):
        pts.append((y, x))
        ang += rng.normal(0, turn)
        y += np.sin(ang)
        x += np.cos(ang)
    return pts, ang


def basalt_columns(cv, x0, width, base, rng, up=True, hmin=40, hmax=200):
    """A cluster of hexagonal basalt columns side by side, stepped flat/angled tops (Giant's
    Causeway), tallest in the middle. Draws into cv; returns the joint lines between columns."""
    joints = []
    x = x0
    while x < x0 + width:
        w = rng.uniform(7, 15)
        t = (x - x0) / width
        hgt = hmin + (hmax - hmin) * np.sin(np.pi * t) ** 0.7 * rng.uniform(0.6, 1.0)
        tilt = rng.uniform(-3, 3)
        s = -1 if up else 1
        y_top = base + s * hgt
        cv.poly([(x, base - s * 4), (x, y_top + tilt), (x + w / 2, y_top - s * 2), (x + w, y_top - tilt),
                 (x + w, base - s * 4)])
        joints.append((x, base, y_top + tilt))
        x += w
    return joints


def cave_far_deep(name, S, rng):
    """The deep backdrop: a vast cavern with huge basalt column clusters, two distant lava
    falls spilling from great hanging rock masses into glowing pools, hot seams in the rock and haze rising
    off the lava. Value only (tinted per zone): lava is full white, rock is dark."""
    sh, top, bot = shelf(S, S, 476, 26, rng, cells=8)
    rock = Canvas(S, S)
    rock.img = Image.fromarray(np.where(sh, 255, 0).astype(np.uint8), "L")
    rock.dr = ImageDraw.Draw(rock.img)
    ceil = lambda x: bot[int(x) % S] - S - 2
    floor = lambda x: top[int(x) % S] + 2
    joints = []
    c1 = rng.uniform(0, S)
    joints += basalt_columns(rock, c1, 120, floor(c1 + 60), rng, True, 50, 260)
    c2 = (c1 + 230) % S
    joints += basalt_columns(rock, c2, 80, floor(c2 + 40), rng, True, 30, 150)
    for cx in ((c1 + 150) % S, (c2 + 140) % S):        # columns hanging from the roof
        joints += basalt_columns(rock, cx, 60, ceil(cx + 30), rng, False, 30, 110)
    hx = (c1 + 330) % S                                 # one colossal pillar, roof to floor
    rock.poly(column_pts(hx, ceil(hx) - 4, floor(hx) + 4, 70, 40, 76, rng))
    for x in place(rng, S, [c1 + 190, c2 + 120], 12, 50):
        spike_cluster(rock, x, ceil(x), rng.uniform(15, 55), rng.uniform(6, 14), rng, True, 1)
    # lava falls
    lava = Canvas(S, S)
    falls = [(c1 + 100) % S, (c2 + 200) % S]
    for fx in falls:
        y0, y1 = rng.uniform(140, 210), floor(fx)
        # a great blunt mass hanging from the roof; the lava spills from its lip
        rock.poly(spike_pts(fx + 6, ceil(fx), y0 - ceil(fx) + 6, rng.uniform(70, 95), rng, True,
                            rng.uniform(-8, 8), 0.3, 12))
        pts = [(fx + 1.5 * np.sin(k * 0.09) + (k / (y1 - y0)) ** 2 * 5, y0 + k) for k in range(int(y1 - y0))]
        lava.line(pts, 150, 8)
        lava.line(pts, 255, 3)
        lava.ellipse(fx - 22, y1 - 4, fx + 30, y1 + 5, fill=150)    # the pool it lands in
        lava.ellipse(fx - 14, y1 - 3, fx + 22, y1 + 3, fill=255)
    m = rock.mask()
    v = shade_rock(m, rng, 0.42, 0.6, 0.12, maxd=18)
    under = m & (~np.roll(m, -1, 0) | ~np.roll(m, -2, 0))    # undersides catch the lava light
    v = np.where(under, 0.72, v)
    jm = Canvas(S, S)                                    # dark joints between the columns
    for x, b, t in joints:
        jm.line([(x, b), (x, t)], 255)
    v = np.where(jm.mask() & m & ~under, v - 0.12, v)
    seams = Canvas(S, S)                                 # glowing seams, only inside the rock
    ys, xs = np.nonzero(dist_to(m, 6) > 4)
    for _ in range(10):
        i = rng.integers(len(ys))
        pts, _ = walk(rng, ys[i], xs[i], int(rng.integers(12, 40)), rng.uniform(0, 6.28), 0.35)
        seams.line([(px, py) for py, px in pts], 255, 1)
    v = np.where(seams.mask() & m, 0.92, v)
    # haze rising off the pools, plus a general warm fog low down
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    haze = np.zeros((S, S))
    wisp = fractal(S, S, 6, 12, 3, rng)
    for fx in falls:
        y1 = floor(fx)
        dx = (xx - fx + S / 2) % S - S / 2
        rise = np.clip((y1 - yy) / 300.0, 0, 1)
        haze = np.maximum(haze, np.exp(-(dx / (30 + 110 * rise)) ** 2) * (1 - rise) * (yy <= y1 + 4))
    haze = np.maximum(haze * (0.55 + 0.6 * wisp), fog_band(S, S, [440], 50, rng, 0.5) * 0.7)
    v = v + (1 - v) * haze * 0.4 * m
    alpha = np.where(m, 1.0, steps(0.1 + haze * 0.45, 16))
    v = np.where(m, v, 1.0)
    la = lava.array() / 255.0                            # lava over everything
    v = np.where(la > 0, np.where(la > 0.7, 1.0, 0.9), v)
    alpha = np.where(la > 0, 1.0, alpha)
    to_rgba(v, alpha).save(os.path.join(OUT, name + ".png"))
    print("wrote", name, f"{m.mean():.0%} solid")


def over_va(v_top, a_top, v_bot, a_bot):
    """Composite one value+alpha layer over another."""
    a = a_top + a_bot * (1 - a_top)
    v = np.where(a > 0, (v_top * a_top + v_bot * a_bot * (1 - a_top)) / np.maximum(a, 1e-6), 1.0)
    return v, a


def cave_far_bottom(name, S, rng):
    """The bottom of the world: a colossal cathedral-like void above the Floor. Enormous carved
    pillars on stepped plinths fade up into darkness, a faint ring structure on the far wall,
    dust shafts falling through. Value only (tinted per zone)."""
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    floor_y = 470
    # far wall: a huge faint ring structure (concentric bands, segmented by spokes)
    rc_x, rc_y = 250.0, 250.0
    dx = (xx - rc_x + S / 2) % S - S / 2
    dy = (yy - rc_y + S / 2) % S - S / 2
    r = np.hypot(dx, dy)
    ang = np.degrees(np.arctan2(dy, dx)) % 360
    ring = np.zeros((S, S))
    for r0, w, a in ((196, 5, 0.3), (178, 2, 0.22), (150, 4, 0.28), (112, 2, 0.2), (84, 3, 0.17)):
        ring = np.maximum(ring, np.where(np.abs(r - r0) <= w / 2, a, 0))
    spokes = (r > 152) & (r < 176) & ((ang % 10) < 1.4)
    ring = np.maximum(ring, np.where(spokes, 0.16, 0))
    glyph_band = (r > 114) & (r < 148) & ((ang % 7.5) < 2.5) & (np.abs(r - 131) < 6) & ((ang // 7.5) % 3 != 0)
    ring = np.maximum(ring, np.where(glyph_band, 0.1, 0))
    ring *= np.clip((yy - 40) / 260, 0, 1) ** 0.7        # fades into darkness towards the top
    ring = np.where(yy < floor_y, ring, 0)
    v, a = np.full((S, S), 0.95), ring
    # dust shafts: soft slanted beams from above with motes in them
    shafts = np.zeros((S, S))
    for sx, w, slope, amp in ((90, 16, 0.18, 0.13), (300, 26, 0.22, 0.16), (420, 10, 0.16, 0.1)):
        cx = sx + yy * slope
        d = np.abs(((xx - cx) + S / 2) % S - S / 2)
        beam = np.clip(1 - d / w, 0, 1) ** 1.5 * amp * np.clip(1 - yy / floor_y, 0, 1) ** 0.6
        shafts = np.maximum(shafts, beam)
        motes = (d < w * 0.8) & (rng.random((S, S)) < 0.004) & (yy < floor_y - 10)
        shafts = np.where(motes, 0.45, shafts)
    v, a = over_va(np.ones((S, S)), steps(shafts, 24), v, a)
    # enormous pillars: plinth steps, fluted shaft, carved bands, fading upward
    pil = Canvas(S, S)
    detail = np.zeros((S, S))                    # -1 dark groove, +1 lit edge
    for px, w in ((40, 62), (236, 74), (400, 54)):
        x0, x1 = px - w / 2, px + w / 2
        pil.rect(x0, 0, x1, floor_y, 255)
        for k, (ext, h) in enumerate(((16, 8), (10, 8), (5, 6))):   # stepped plinth
            yb = floor_y - sum(hh for _, hh in ((16, 8), (10, 8), (5, 6))[:k])
            pil.rect(x0 - ext, yb - h, x1 + ext, yb, 255)
        xs = np.arange(int(x0) + 6, int(x1) - 4, 7)                    # fluting
        for fx in xs:
            col = (xx % S == fx % S) & (yy < floor_y - 26)
            detail = np.where(col, -1, detail)
            detail = np.where((xx % S == (fx + 1) % S) & (yy < floor_y - 26), 1, detail)
        for by in (floor_y - 90, floor_y - 210, floor_y - 330):        # carved bands with a ring motif
            band = (np.abs(yy - by) <= 5) & (((xx - x0) % S) < w)
            detail = np.where(band, 0.5, detail)
            detail = np.where((np.abs(yy - by) == 6) & (((xx - x0) % S) < w), -1, detail)
            cr = np.hypot(((xx - px + S / 2) % S - S / 2), yy - by)
            detail = np.where((np.abs(cr - 9) < 0.8) | (np.abs(cr - 4) < 0.7), -1, detail)
    pm = pil.mask() & (yy < floor_y)
    pv = shade_rock(pm, rng, 0.62, 0.78, 0.12, maxd=24)
    pv = np.where(pm & (detail < 0), pv - 0.14, pv)
    pv = np.where(pm & (detail > 0), pv + 0.08 * detail, pv)
    left_edge = pm & ~np.roll(pm, 1, 1)
    pv = np.where(left_edge | (pm & ~np.roll(pm, 2, 1)), pv + 0.12, pv)
    fade = np.clip((yy - 30) / 300.0, 0, 1) ** 1.3            # pillars dissolve into the dark above
    pa = np.where(pm, fade, 0.0)
    pv = pv + (1 - pv) * shafts * 1.5 * pm                  # beams graze the pillars
    v, a = over_va(pv, steps(pa, 16), v, a)
    # the Floor itself: a dead-straight band of carved blocks
    fl = (yy >= floor_y) & (yy < floor_y + 34)
    fv = np.full((S, S), 0.62)
    fv = np.where(yy == floor_y, 0.86, fv)
    fv = np.where(yy == floor_y + 1, 0.76, fv)
    seams = ((xx % 64) == 0) & (yy > floor_y + 2)
    seams |= (yy == floor_y + 17) | (((xx + 32) % 64 == 0) & (yy > floor_y + 17))
    fv = np.where(seams, 0.44, fv)
    fv = fv + (fractal(S, S, 4, 8, 2, rng) - 0.5) * 0.04
    v, a = over_va(np.round(fv * 32) / 32, fl.astype(float), v, a)
    to_rgba(v, a).save(os.path.join(OUT, name + ".png"))
    print("wrote", name, f"{(a > 0.99).mean():.0%} solid")


def ice_spire(lit, dark, x, base, hgt, width, rng, up=True):
    """A faceted ice spire (a bundle of angular crystals): the left half goes to `lit`, the
    right half to `dark`, so the two planes read as facets catching the cold light."""
    s = -1 if up else 1
    tip = (x + rng.uniform(-0.12, 0.12) * width, base + s * hgt)
    kink_y = base + s * hgt * rng.uniform(0.45, 0.65)
    kl = (x - width * rng.uniform(0.4, 0.55), kink_y)
    kr = (x + width * rng.uniform(0.4, 0.55), kink_y)
    foot_l, foot_r = (x - width / 2 - 2, base - s * 5), (x + width / 2 + 2, base - s * 5)
    mid = (tip[0] + rng.uniform(-0.1, 0.1) * width, base - s * 5)
    lit.poly([foot_l, kl, tip, mid])
    dark.poly([mid, tip, kr, foot_r])


def cave_far_ice(name, S, rng):
    """The frozen layer's backdrop: a rime-crusted cavern with towers of faceted ice rising
    from the floor, long icicles hanging from the roof, two frozen waterfalls and drifting
    snow. Value only (tinted per zone): ice is light, the crust beneath it a darker grey."""
    sh, top, bot = shelf(S, S, 476, 26, rng, cells=8)
    rock = Canvas(S, S)
    rock.img = Image.fromarray(np.where(sh, 255, 0).astype(np.uint8), "L")
    rock.dr = ImageDraw.Draw(rock.img)
    ceil = lambda x: bot[int(x) % S] - S - 2
    floor = lambda x: top[int(x) % S] + 2
    lit, dark = Canvas(S, S), Canvas(S, S)
    c1 = rng.uniform(0, S)
    for x in place(rng, S, [c1, c1 + 250], 8, 55):                 # towers growing from the floor
        h = rng.uniform(70, 280)
        w = 14 + h * rng.uniform(0.1, 0.2)
        ice_spire(lit, dark, x, floor(x), h, w, rng, True)
        for _ in range(int(rng.integers(1, 3))):                    # daughter crystals at the foot
            dx = rng.uniform(-0.9, 0.9) * w
            ice_spire(lit, dark, x + dx, floor(x + dx), h * rng.uniform(0.2, 0.5), w * 0.5, rng, True)
    for x in place(rng, S, [c1 + 120, c1 + 380], 11, 70):          # icicles from the roof
        spike_cluster(rock, x, ceil(x), rng.uniform(40, 190), rng.uniform(6, 15), rng, True, 2)
    for x in place(rng, S, [c1 + 60, c1 + 300], 5, 60):            # a few downward ice crystals too
        ice_spire(lit, dark, x, ceil(x), rng.uniform(30, 110), rng.uniform(10, 20), rng, False)
    # frozen waterfalls: a ridged curtain of ice from a hanging mass down to a drift of snow
    falls = [(c1 + 190) % S, (c1 + 450) % S]
    curtain = Canvas(S, S)
    for fx in falls:
        y0, y1 = rng.uniform(120, 190), floor(fx)
        rock.poly(spike_pts(fx + 4, ceil(fx), y0 - ceil(fx) + 6, rng.uniform(70, 95), rng, True,
                            rng.uniform(-6, 6), 0.3, 12))
        wd = rng.uniform(15, 22)
        left, right = [], []
        for k in range(int(y1 - y0) + 1):
            t = k / max(y1 - y0, 1)
            w = wd * (0.55 + 0.45 * np.sin(np.pi * min(t * 1.2 + 0.1, 1)) + 0.5 * t ** 3) * (1 + 0.08 * np.sin(k * 0.21 + fx))
            cx = fx + 1.5 * np.sin(k * 0.05) + t * t * 3
            left.append((cx - w / 2, y0 + k))
            right.append((cx + w / 2, y0 + k))
        curtain.poly(left + right[::-1])
        curtain.ellipse(fx - 38, y1 - 9, fx + 42, y1 + 7, fill=255)    # the snow drift it lands in
    # value
    cm = curtain.mask()
    lm, dm = lit.mask(), dark.mask()
    m = rock.mask() | lm | dm | cm
    v = shade_rock(m, rng, 0.62, 0.9, 0.22, maxd=20)
    v = np.where(lm & ~cm, np.minimum(v + 0.2, 0.98), v)
    v = np.where(dm & ~lm & ~cm, v - 0.14, v)
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    ridge = cm & (((xx.astype(int) + (yy * 0.04).astype(int)) % 4) == 0)         # vertical flutes
    v = np.where(cm, np.where(ridge, 0.82, 0.96), v)
    v = np.where(cm & ~np.roll(cm, 1, 1), 1.0, v)
    # glints: thin bright cracks and facet lines running through the ice
    gl = Canvas(S, S)
    ys, xs = np.nonzero(dist_to(lm | dm, 6) > 3)
    for _ in range(18):
        i = rng.integers(len(ys))
        pts, _ = walk(rng, ys[i], xs[i], int(rng.integers(8, 26)), -1.1 + rng.normal(0, 0.5), 0.12)
        gl.line([(px, py) for py, px in pts], 255, 1)
    v = np.where(gl.mask() & (lm | dm), 1.0, v)
    # the rock crust under the ice stays darker and cooler
    crust = rock.mask() & ~lm & ~dm & ~cm
    v = np.where(crust, v * 0.78, v)
    # cold mist low down, snow drifting through the cavern
    haze = fog_band(S, S, [450, 300], 55, rng, 0.6) * 0.7
    v = v + (1 - v) * haze * 0.35 * m
    snow = np.zeros((S, S))
    flakes = rng.random((S, S)) < 0.0035
    snow = np.where(flakes, 1.0, 0.0)
    snow = np.maximum(snow, np.roll(snow, 1, 1) * 0.5)
    snow = np.maximum(snow, np.roll(snow, 1, 0) * 0.5)
    alpha = np.where(m, 1.0, steps(0.08 + haze * 0.4, 16))
    v = np.where(m, v, 1.0)
    v = np.where(~m & (snow > 0), 1.0, v)
    alpha = np.where(~m & (snow > 0), np.maximum(alpha, 0.35 + 0.5 * snow), alpha)
    to_rgba(v, alpha).save(os.path.join(OUT, name + ".png"))
    print("wrote", name, f"{m.mean():.0%} solid")


def mushroom(stem, cap, gill, spots, x, base, hgt, capw, rng, lean=0.0):
    """A big cave mushroom silhouette: curved tapering stem, domed cap with a glowing
    underside rim and a few glowing spots. Draws into the four canvases."""
    caph = capw * rng.uniform(0.28, 0.4)
    ycap = base - hgt
    wb, wt = capw * rng.uniform(0.16, 0.24), capw * rng.uniform(0.09, 0.14)
    left, right = [], []
    for i in range(13):
        t = i / 12
        w = wb + (wt - wb) * t ** 0.7
        cx = x + lean * t * t
        left.append((cx - w / 2, base + 4 - (hgt + 4) * t))
        right.append((cx + w / 2, base + 4 - (hgt + 4) * t))
    stem.poly(left + right[::-1])
    cx = x + lean
    dome = [(cx + capw / 2 * np.cos(a) * (1 + 0.04 * np.sin(5 * a)), ycap + caph * np.sin(a)) for a in np.linspace(np.pi, 2 * np.pi, 28)]
    under = [(cx + capw / 2 * t, ycap - 0.22 * caph * (1 - t * t)) for t in np.linspace(1, -1, 14)]
    cap.poly(dome + under)
    gill.line(under, 255, 2)
    for _ in range(int(rng.integers(5, 10))):                   # spots on the dome
        a = rng.uniform(0.15, 0.85)
        sx = cx + capw / 2 * (2 * a - 1) * 0.8
        sy = ycap - caph * 0.8 * np.sqrt(max(1 - (2 * a - 1) ** 2, 0)) * rng.uniform(0.3, 0.9)
        r = rng.uniform(2.5, 6.5) * capw / 100 + 1.2
        spots.ellipse(sx - r, sy - r * 0.7, sx + r, sy + r * 0.7, fill=255)


def cave_far_fungal(name, S, rng):
    """The fungal layer's backdrop: a dark, damp cavern with towering mushrooms whose caps and
    gills glow, clusters of small ones on the floor, glowing threads hanging from the roof and
    spores drifting in the haze. Value only (tinted dark teal in game): the rock is dark, the
    glowing mushroom parts are full white and throw a soft halo."""
    sh, top, bot = shelf(S, S, 478, 30, rng, cells=7)
    rock = Canvas(S, S)
    rock.img = Image.fromarray(np.where(sh, 255, 0).astype(np.uint8), "L")
    rock.dr = ImageDraw.Draw(rock.img)
    ceil = lambda x: bot[int(x) % S] - S - 2
    floor = lambda x: top[int(x) % S] + 2
    c1 = rng.uniform(0, S)
    for x in place(rng, S, [c1 + 40, c1 + 300], 10, 80):           # stalactites
        spike_cluster(rock, x, ceil(x), rng.uniform(20, 120), rng.uniform(8, 20), rng, True, 2)
    for x in place(rng, S, [c1 + 150, c1 + 400], 5, 60):           # a few rock columns
        rock.poly(column_pts(x, ceil(x) - 4, floor(x) + 4, rng.uniform(34, 60), rng.uniform(16, 26), rng.uniform(40, 70), rng))
    for x in place(rng, S, [c1, c1 + 230], 6, 60):                 # mounds on the floor
        w, h = rng.uniform(60, 150), rng.uniform(20, 70)
        pts = [(x - w / 2 + w * k / 16, floor(x) + 6 - h * np.sin(np.pi * k / 16) ** 1.3 * (1 + 0.15 * np.sin(k * 2.3 + x)))
               for k in range(17)]
        rock.poly(pts)
    stem, cap, gill, spots = Canvas(S, S), Canvas(S, S), Canvas(S, S), Canvas(S, S)
    big = [(c1 + 20, 270, 150), (c1 + 140, 190, 120), (c1 + 235, 300, 180), (c1 + 330, 150, 100),
           (c1 + 430, 230, 140)]
    for bx, h, cw in big:                                           # the towering ones
        bx %= S
        mushroom(stem, cap, gill, spots, bx, floor(bx) + 2, h * rng.uniform(0.85, 1.1), cw * rng.uniform(0.9, 1.15), rng,
                 rng.uniform(-20, 20))
    for bx, _, _ in big:                                            # little ones crowding round each
        for _ in range(int(rng.integers(3, 7))):
            sx = (bx + rng.normal(0, 55)) % S
            hh = rng.uniform(14, 52)
            mushroom(stem, cap, gill, spots, sx, floor(sx) + 2, hh, hh * rng.uniform(0.8, 1.5), rng, rng.uniform(-4, 4))
    threads = Canvas(S, S)                                          # glow-worm threads from the roof
    beads = Canvas(S, S)
    for x in place(rng, S, [c1 + 90, c1 + 360], 12, 90):
        y0, L = ceil(x), rng.uniform(30, 120)
        pts = [(x + 2 * np.sin(k * 0.15 + x), y0 + k) for k in range(int(L))]
        threads.line(pts, 255, 1)
        for k in range(8, int(L), int(rng.integers(8, 14))):
            bx, by = pts[k]
            beads.ellipse(bx - 1.2, by - 1.2, bx + 1.2, by + 1.2, fill=255)
    rm, sm, cm, gm, pm = rock.mask(), stem.mask(), cap.mask(), gill.mask(), spots.mask()
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    v = shade_rock(rm, rng, 0.3, 0.5, 0.1, maxd=18)
    vs = shade_rock(sm, rng, 0.46, 0.66, 0.16, maxd=8)
    right_edge = sm & ~np.roll(sm, -1, 1)
    vs = np.where(right_edge, vs - 0.1, vs)
    vc = shade_rock(cm, rng, 0.5, 0.72, 0.16, maxd=10)
    m = rm | sm | cm
    v = np.where(sm, vs, v)
    v = np.where(cm, vc, v)
    v = np.where(gm & cm, 1.0, v)                                   # glowing gills under the cap
    v = np.where(pm & cm, 1.0, v)                                   # glowing spots
    tm = threads.mask() & ~m
    v = np.where(tm, 0.7, v)
    bm = beads.mask()
    v = np.where(bm, 1.0, v)
    m = m | tm | bm
    # soft halo round everything that glows
    glow_src = (gm & cm) | (pm & cm) | bm
    halo = np.clip(1 - dist_to(~glow_src, 16) / 16.0, 0, 1) ** 2        # distance to the nearest glowing pixel
    cap_halo = np.clip(1 - dist_to(~cm, 14) / 14.0, 0, 1) ** 2 * 0.5
    haze = np.maximum(halo * 0.5, cap_halo)
    mist = fog_band(S, S, [455, 330], 50, rng, 0.6) * 0.35
    haze = np.maximum(haze, mist)
    alpha = np.where(m, 1.0, steps(0.06 + haze * 0.6, 16))
    v = np.where(m, v, 1.0)
    spores = rng.random((S, S)) < 0.003
    sp = np.where(spores, 1.0, 0.0)
    sp = np.maximum(sp, np.roll(sp, 1, 1) * 0.5)
    alpha = np.where(~m & (sp > 0), np.maximum(alpha, 0.3 + 0.5 * sp), alpha)
    to_rgba(v, alpha).save(os.path.join(OUT, name + ".png"))
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
    import sys
    if sys.argv[1:]:             # e.g. `gen_backgrounds.py cave_far_ice` regenerates just those
        extra = {"cave_far_ice": lambda: cave_far_ice("cave_far_ice", 512, np.random.default_rng(2032)),
                 "cave_far_fungal": lambda: cave_far_fungal("cave_far_fungal", 512, np.random.default_rng(2033))}
        for a in sys.argv[1:]:
            extra[a]()
        sys.exit(0)
    cave_far("cave_far", 512, np.random.default_rng(2024))
    cave_mid("cave_mid", 512, np.random.default_rng(2025))
    cave_near("cave_near", 512, np.random.default_rng(2026))
    cave_far_deep("cave_far_deep", 512, np.random.default_rng(2030))
    cave_far_bottom("cave_far_bottom", 512, np.random.default_rng(2031))
    hills_far("hills_far", 1024, 160, np.random.default_rng(2027))
    hills_near("hills_near", 1024, 160, np.random.default_rng(2028))
    dead_forest("forest", 1024, 160, np.random.default_rng(2029))
    cave_far_ice("cave_far_ice", 512, np.random.default_rng(2032))
    cave_far_fungal("cave_far_fungal", 512, np.random.default_rng(2033))
