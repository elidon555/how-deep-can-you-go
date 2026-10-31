#!/usr/bin/env python3
"""Synthesizes every sound effect of the game into assets/sfx/ (16-bit mono 44.1 kHz WAV).

Pure numpy (scipy.signal.lfilter is used only to speed up filtering if installed).
Fixed seeds, so every run writes identical files. One-shots get a short fade in/out
and are peak-normalized to -3 dBFS. The loops (amb_cave, amb_deep, drill_loop,
drill_idle, turret_turn, worm_burrow) are built periodic (every sine, LFO and noise spectrum has a whole number
of cycles per loop), so they loop seamlessly; ambience peaks at -12 dBFS, drill_loop
at -10, drill_idle at -16, turret_turn at -18, worm_burrow at -12.

Run:  python3 tools/gen_sfx.py
"""
import os
import wave
import numpy as np

try:
    from scipy.signal import lfilter as _scipy_lfilter
except ImportError:
    _scipy_lfilter = None

SR = 44100
TAU = 2 * np.pi
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "sfx")


# ----------------------------------------------------------------------------- basics

def secs(d):
    return int(round(d * SR))


def times(n):
    return np.arange(n) / SR


def unit(x):
    """Scale to peak 1 (silence stays silence)."""
    m = np.max(np.abs(x))
    return x / m if m > 0 else x


def noise(n, rng):
    return rng.standard_normal(n)


def env(n, attack, decay, delay=0.0):
    """Linear attack, then exponential decay with time constant `decay` (s), starting at `delay`."""
    t = times(n) - delay
    rise = np.clip(t / max(attack, 1e-6), 0.0, 1.0)
    return rise * np.exp(-np.maximum(t - attack, 0.0) / decay)


def glide(f0, f1, n, time):
    """Exponential frequency glide f0 -> f1 over `time` seconds, then held (per-sample Hz)."""
    p = np.minimum(times(n) / time, 1.0)
    return f0 * (f1 / f0) ** p


def osc(freq, n=None):
    """Sine with per-sample frequency (phase-integrated, so sweeps stay smooth)."""
    f = np.full(n, float(freq)) if n is not None else np.asarray(freq, float)
    return np.sin(TAU * (np.cumsum(f) - f[0]) / SR)


def harmonic(f0, tilt=1.0, fmax=8000.0):
    """Band-limited buzzy source: sum of harmonics k*f0 with 1/k^tilt, faded out above fmax."""
    phase = TAU * (np.cumsum(f0) - f0[0]) / SR
    out = np.zeros(len(f0))
    for k in range(1, int(fmax / np.min(f0)) + 1):
        gain = np.clip((fmax - k * f0) / (0.15 * fmax), 0.0, 1.0)
        out += gain * np.sin(k * phase) / k ** tilt
    return out


def modes(n, freqs, decays, amps, delay=0.0):
    """Struck resonator: sum of exponentially decaying sines (bells, clinks, rings)."""
    t = times(n) - delay
    on = t >= 0
    tp = np.where(on, t, 0.0)
    out = np.zeros(n)
    for f, d, a in zip(freqs, decays, amps):
        out += a * np.sin(TAU * f * tp) * np.exp(-tp / d)
    return out * on * np.clip(tp / 0.0005, 0.0, 1.0)


def place(n, t0, x):
    """Put signal x into an n-sample buffer starting at t0 seconds."""
    out = np.zeros(n)
    i = secs(t0)
    m = min(len(x), n - i)
    if m > 0:
        out[i:i + m] = x[:m]
    return out


# ----------------------------------------------------------------------------- filters

def lfilter(b, a, x):
    """Second-order IIR (b, a already normalized so a[0] == 1)."""
    if _scipy_lfilter is not None:
        return _scipy_lfilter(b, a, x)
    b0, b1, b2 = b
    a1, a2 = a[1], a[2]
    x1 = x2 = y1 = y2 = 0.0
    out = [0.0] * len(x)
    for i, xi in enumerate(x.tolist()):
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, xi, y1, yi
        out[i] = yi
    return np.array(out)


def biquad(x, kind, f, q=0.707):
    """RBJ-cookbook biquad: 'lp', 'hp' or 'bp' (band-pass with 0 dB peak)."""
    w = TAU * min(f, SR * 0.45) / SR
    cw, al = np.cos(w), np.sin(w) / (2 * q)
    if kind == "lp":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
    elif kind == "hp":
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
    else:
        b = [al, 0.0, -al]
    a0 = 1 + al
    return lfilter([c / a0 for c in b], [1.0, -2 * cw / a0, (1 - al) / a0], x)


def svf(x, freq, q=1.0, mode="bp"):
    """TPT state-variable filter with per-sample cutoff (for sweeps / moving formants).
    'bp' is normalized to 0 dB at the centre, 'lp' is the plain low-pass output."""
    n = len(x)
    freq = np.clip(np.broadcast_to(np.asarray(freq, float), (n,)), 10.0, SR * 0.45)
    g = np.tan(np.pi * freq / SR)
    k = 1.0 / q
    a1 = 1.0 / (1.0 + g * (g + k))
    a2 = g * a1
    a3 = g * a2
    ic1 = ic2 = 0.0
    bp, lp = [0.0] * n, [0.0] * n
    for i, (xi, c1, c2, c3) in enumerate(zip(x.tolist(), a1.tolist(), a2.tolist(), a3.tolist())):
        v3 = xi - ic2
        v1 = c1 * ic1 + c2 * v3
        v2 = ic2 + c2 * ic1 + c3 * v3
        ic1, ic2 = 2 * v1 - ic1, 2 * v2 - ic2
        bp[i], lp[i] = v1, v2
    return k * np.array(bp) if mode == "bp" else np.array(lp)


def formants(x, specs):
    """Parallel resonances [(freq or per-sample freq array, q, gain), ...] -> vowel-ish colour."""
    return sum(gain * svf(x, f, q) for f, q, gain in specs)


def spectral(x, shape):
    """Circular filtering in the frequency domain (keeps periodic loops periodic)."""
    f = np.fft.rfftfreq(len(x), 1 / SR)
    return np.fft.irfft(np.fft.rfft(x) * shape(f), len(x))


def comb(x, delay, fb):
    """Feedback delay y[n] = x[n] + fb*y[n-d], vectorized one delay-length block at a time."""
    d = max(1, secs(delay))
    y = x.copy()
    for k in range(d, len(y), d):
        m = min(d, len(y) - k)
        y[k:k + m] += fb * y[k - d:k - d + m]
    return y


def allpass(x, delay, g):
    d = max(1, secs(delay))
    v = -g * x
    v[d:] += x[:-d]
    return comb(v, delay, g)


def reverb(x, size=1.0, fb=0.7, mix=0.3, damp=4000.0,
           delays=(0.0297, 0.0371, 0.0411, 0.0437)):
    """Small Schroeder reverb: damped parallel combs + two allpass diffusers."""
    damped = biquad(x, "lp", damp)
    wet = sum(comb(damped, d * size, fb) for d in delays) / len(delays)
    for d in (0.005, 0.0017):
        wet = allpass(wet, d, 0.7)
    return x + mix * wet


# ----------------------------------------------------------------------------- textures

def burst(n, rng, attack, decay, kind="bp", f=1000.0, q=0.7, delay=0.0):
    """Enveloped, filtered noise burst, peak 1."""
    return unit(biquad(noise(n, rng) * env(n, attack, decay, delay), kind, f, q))


def wobble(n, rng, rate):
    """Smooth random control signal in [-1, 1]."""
    return unit(biquad(noise(n, rng), "lp", rate, 0.6))


def rough(n, rng, rate):
    """Random positive amplitude flutter in [0, 1]."""
    return unit(np.abs(biquad(noise(n, rng), "lp", rate, 0.6)))


def grains(n, rng, count, t0, t1, fmin, fmax, length=(0.002, 0.008), decay=0.1, q=1.5, skew=1.7):
    """Scatter of tiny filtered noise ticks (gravel, crumbs, debris), denser and louder early
    (skew=1 spreads them evenly)."""
    out = np.zeros(n)
    for _ in range(count):
        start = t0 + (t1 - t0) * rng.random() ** skew
        size = max(8, secs(rng.uniform(*length)))
        g = np.zeros(3 * size)
        g[:size] = noise(size, rng) * np.exp(-np.linspace(0, 4, size))
        g = biquad(g, "bp", np.exp(rng.uniform(np.log(fmin), np.log(fmax))), q)
        out += rng.uniform(0.3, 1.0) * np.exp(-(start - t0) / decay) * place(n, start, g)
    return out


def bubbles(n, rng, count, t0, t1, fmin, fmax):
    """Short rising sine chirps: wet gurgles / squelch bubbles."""
    out = np.zeros(n)
    m = secs(0.03)
    for _ in range(count):
        f = rng.uniform(fmin, fmax)
        b = osc(glide(f, f * 2.5, m, 0.025)) * env(m, 0.002, 0.007)
        out += rng.uniform(0.4, 1.0) * place(n, rng.uniform(t0, t1), b)
    return out


def finish(x, peak_db=-3.0, fade_in=0.002, fade_out=None):
    """High-pass away DC, raised-cosine fades to exact zero, peak-normalize."""
    x = biquad(np.asarray(x, float), "hp", 25.0)
    if fade_out is None:
        fade_out = min(0.03, 0.15 * len(x) / SR)
    fi, fo = secs(fade_in), secs(fade_out)
    x[:fi] *= 0.5 - 0.5 * np.cos(np.pi * np.linspace(0, 1, fi))
    x[-fo:] *= 0.5 + 0.5 * np.cos(np.pi * np.linspace(0, 1, fo))
    return unit(x) * 10 ** (peak_db / 20)


# ----------------------------------------------------------------------------- digging

def hit_dirt(v=0):
    rng = np.random.default_rng(1000 + v)
    n, p = secs(0.25), 1 + 0.07 * (v - 1)
    thud = osc(glide(150 * p, 55 * p, n, 0.05)) * env(n, 0.002, 0.045)
    body = burst(n, rng, 0.001, 0.03, "lp", 450 * p)
    hiss = unit(biquad(noise(n, rng) * env(n, 0.004, 0.05) * rough(n, rng, 60), "bp", 1300 * p))
    crumbs = unit(grains(n, rng, 26, 0.01, 0.2, 600, 3000, decay=0.07))
    return finish(thud + 0.7 * body + 0.25 * hiss + 0.35 * crumbs)


def hit_stone(v=0):
    rng = np.random.default_rng(1100 + v)
    n = secs(0.35)
    freqs = np.array([1650, 2270, 2930, 4150]) * (1 + 0.04 * (v - 1) + rng.uniform(-0.03, 0.03, 4))
    click = burst(n, rng, 0.0002, 0.003, "hp", 3000)
    decays = np.array([0.09, 0.065, 0.05, 0.025]) * rng.uniform(0.8, 1.2, 4)
    ring = unit(modes(n, freqs, decays, [1.0, 0.7, 0.5, 0.3]))
    knock = osc(glide(330, 170, n, 0.03)) * env(n, 0.001, 0.018)
    grit = unit(grains(n, rng, 10, 0.003, 0.09, 2000, 7000, length=(0.001, 0.004), decay=0.03))
    return finish(0.9 * click + 0.55 * ring + 0.5 * knock + 0.25 * grit)


def hit_hard(v=0):
    rng = np.random.default_rng(1200 + v)
    n = secs(0.6)
    ratios = np.array([1.0, 1.52, 2.76, 3.43, 5.40, 6.93]) * (1 + rng.uniform(-0.015, 0.015, 6))
    f = 800 * (1 + 0.05 * (v - 1)) * ratios
    decays = [0.30, 0.23, 0.18, 0.12, 0.08, 0.05]
    amps = np.array([0.8, 0.6, 1.0, 0.5, 0.45, 0.25])
    ring = modes(n, f, decays, amps) + modes(n, f * 1.0025 + 1.3, decays, 0.6 * amps)  # twins beat
    click = burst(n, rng, 0.0002, 0.002, "hp", 4000)
    clang = burst(n, rng, 0.0005, 0.012, "bp", 2600, 1.2)
    thump = osc(glide(260, 150, n, 0.03)) * env(n, 0.001, 0.025)
    return finish(np.tanh(1.5 * (0.8 * click + 0.5 * clang + 0.75 * unit(ring) + 0.35 * thump)), fade_out=0.1)


def bonk(v=0):
    rng = np.random.default_rng(1300 + v)
    n = secs(0.2)
    knock = osc(glide(230, 140, n, 0.04)) * env(n, 0.001, 0.035)
    wood = unit(modes(n, [480, 820, 1350], [0.035, 0.02, 0.01], [1.0, 0.5, 0.25]))
    tap = burst(n, rng, 0.0005, 0.008, "bp", 700, 1.5)
    return finish(biquad(knock + 0.45 * wood + 0.5 * tap, "lp", 2500))


def rock_break(v=0):
    rng = np.random.default_rng(1400 + v)
    n = secs(0.5)
    crack = burst(n, rng, 0.0005, 0.012, "bp", 2400 * (1 + 0.1 * v), 0.8)
    thump = osc(glide(140, 60, n, 0.06)) * env(n, 0.002, 0.06)
    crumble = unit(biquad(noise(n, rng) * rough(n, rng, 45) * env(n, 0.01, 0.12), "bp", 900, 0.8))
    debris = unit(grains(n, rng, 70, 0.0, 0.42, 400, 4500, decay=0.16))
    bits = unit(grains(n, rng, 30, 0.04, 0.45, 3000, 8000, length=(0.001, 0.003), decay=0.2))
    return finish(0.7 * crack + 0.6 * thump + 0.35 * crumble + 0.9 * debris + 0.35 * bits)


def swing(v=0):
    rng = np.random.default_rng(1500 + v)
    n = secs(0.2)
    p = np.arange(n) / n
    centre = 450 + 2200 * np.sin(np.pi * p ** 0.85) ** 2   # sweeps up, then back down
    amp = np.sin(np.pi * p ** 0.75) ** 2
    whoosh = unit(svf(noise(n, rng) * amp, centre, q=2.5))
    low = unit(biquad(noise(n, rng) * amp, "lp", 350))
    return finish(whoosh + 0.3 * low)


# ----------------------------------------------------------------------------- player

def step(v=0):
    rng = np.random.default_rng(1600 + v)
    n, p = secs(0.12), 1 + 0.08 * (v - 1.5)
    thud = burst(n, rng, 0.002, 0.018, "lp", 320 * p)
    tone = osc(glide(115 * p, 70 * p, n, 0.03)) * env(n, 0.002, 0.02)
    scuff = burst(n, rng, 0.003, 0.012, "bp", 2200 * p, 0.8)
    grit = unit(grains(n, rng, 9, 0.002, 0.07, 1500, 6000, length=(0.001, 0.004), decay=0.03))
    return finish(biquad(0.8 * thud + 0.4 * tone + 0.25 * scuff + 0.4 * grit, "lp", 6000))


def land(v=0):
    rng = np.random.default_rng(1700 + v)
    n = secs(0.3)
    thump = osc(glide(110, 45, n, 0.08)) * env(n, 0.002, 0.07)
    body = burst(n, rng, 0.001, 0.05, "lp", 260)
    slap = burst(n, rng, 0.0005, 0.01, "bp", 1200, 0.8)
    gravel = unit(grains(n, rng, 35, 0.005, 0.22, 800, 5000, decay=0.07))
    return finish(thump + 0.7 * body + 0.3 * slap + 0.4 * gravel)


def jump(v=0):
    rng = np.random.default_rng(1800 + v)
    n = secs(0.15)
    scuff = burst(n, rng, 0.001, 0.015, "bp", 2500, 0.9)
    grit = unit(grains(n, rng, 6, 0.0, 0.04, 2000, 6000, length=(0.001, 0.003), decay=0.03))
    cloth = unit(svf(noise(n, rng) * env(n, 0.02, 0.035), glide(900, 2400, n, 0.08), q=1.5))
    breath = unit(formants(noise(n, rng) * env(n, 0.015, 0.03, delay=0.01),
                           [(700, 5, 1.0), (1150, 6, 0.7), (2600, 8, 0.3)]))
    return finish(0.5 * scuff + 0.25 * grit + 0.6 * cloth + 0.3 * breath)


def player_hurt(v=0):
    rng = np.random.default_rng(1900 + v)
    n = secs(0.3)
    f0 = glide(150, 95, n, 0.14) * (1 + 0.03 * wobble(n, rng, 40))
    src = unit(harmonic(f0, tilt=1.2, fmax=5000)) + 0.3 * unit(biquad(noise(n, rng), "lp", 3000))
    voice = unit(formants(src, [(600, 5, 1.0), (1000, 6, 0.6), (2400, 8, 0.2)]))  # "uh"
    grunt = np.tanh(1.5 * voice * env(n, 0.012, 0.06, delay=0.01))
    thump = osc(glide(120, 55, n, 0.05)) * env(n, 0.002, 0.05)
    hit = burst(n, rng, 0.0005, 0.02, "bp", 1500, 0.7)
    return finish(0.8 * grunt + 0.7 * thump + 0.5 * hit)


# ----------------------------------------------------------------------------- world / ui

def ore(v=0):
    rng = np.random.default_rng(2000 + v)
    n = secs(0.7)
    chime = np.zeros(n)
    for t0, f, a in [(0.0, 1318.5, 1.0), (0.075, 1975.5, 0.85), (0.15, 2637.0, 0.75)]:  # E6 B6 E7
        chime += a * modes(n, [f, f * 1.003, 2 * f, 2.76 * f, 5.4 * f],
                           [0.25, 0.24, 0.15, 0.08, 0.04], [1.0, 0.5, 0.22, 0.15, 0.05], delay=t0)
    sparkle = np.zeros(n)
    for _ in range(16):
        t0 = rng.uniform(0.03, 0.45)
        sparkle += modes(n, [rng.uniform(5000, 9000)], [0.015],
                         [rng.uniform(0.3, 1.0) * np.exp(-t0 / 0.25)], delay=t0)
    return finish(reverb(unit(chime) + 0.25 * unit(sparkle), mix=0.25), fade_out=0.12)


def coins(v=0):
    rng = np.random.default_rng(2100 + v)
    n = secs(0.5)
    x = np.zeros(n)
    for i, t0 in enumerate([0.0, 0.06, 0.13, 0.24]):
        t0 += rng.uniform(0, 0.02)
        f = rng.uniform(2600, 3600) * np.array([1, 1.47, 2.13, 2.66, 3.42]) * (1 + rng.uniform(-0.02, 0.02, 5))
        clink = modes(n, f, [0.12, 0.08, 0.06, 0.045, 0.03], [1.0, 0.7, 0.6, 0.4, 0.3], delay=t0)
        click = burst(n, rng, 0.0002, 0.0015, "hp", 5000, delay=t0)
        x += (1 - 0.15 * i) * (clink + 0.6 * click)
    return finish(reverb(x, mix=0.15), fade_out=0.08)


def ui_click(v=0):
    rng = np.random.default_rng(2200 + v)
    n = secs(0.05)
    tick = osc(glide(2100, 1400, n, 0.01)) * env(n, 0.0005, 0.005)
    body = osc(520, n) * env(n, 0.0005, 0.008)
    snap = burst(n, rng, 0.0002, 0.0015, "bp", 3500, 1.0)
    return finish(biquad(tick + 0.4 * body + 0.3 * snap, "lp", 6000), fade_in=0.0005, fade_out=0.01)


def rope(v=0):
    rng = np.random.default_rng(2300 + v)
    n = secs(0.6)
    whip = unit(svf(noise(n, rng) * env(n, 0.01, 0.05), glide(500, 4500, n, 0.09), q=2.0))
    rustle_amp = env(n, 0.06, 0.18, delay=0.04) * rough(n, rng, 35)
    rustle = unit(svf(noise(n, rng) * rustle_amp, 1400 + 900 * wobble(n, rng, 8), q=1.2))
    ticks = unit(grains(n, rng, 45, 0.06, 0.55, 2000, 7000, length=(0.001, 0.003), decay=0.25))
    slaps = sum(a * burst(n, rng, 0.001, 0.015, "bp", 450, 1.0, delay=t0)
                for t0, a in [(0.18, 1.0), (0.31, 0.7), (0.45, 0.45)])
    return finish(0.8 * whip + 0.6 * rustle + 0.35 * ticks + 0.3 * slaps, fade_out=0.06)


def rockfall(v=0):
    rng = np.random.default_rng(2400 + v)
    n, hit = secs(0.8), 0.32
    t = times(n)
    scrape_amp = np.clip(t / 0.25, 0, 1) ** 1.5 * np.clip((hit - t) / 0.01, 0, 1)
    scrape = unit(biquad(noise(n, rng) * rough(n, rng, 70) * scrape_amp, "bp", 1700, 1.3))
    ticks = unit(grains(n, rng, 15, 0.05, hit, 1500, 5000, length=(0.001, 0.004), decay=1.0))
    m = n - secs(hit)
    thump = place(n, hit, osc(glide(95, 38, m, 0.1)) * env(m, 0.002, 0.12))
    body = burst(n, rng, 0.001, 0.08, "lp", 300, delay=hit)
    crack = burst(n, rng, 0.0005, 0.01, "bp", 2000, 0.8, delay=hit)
    rubble = unit(grains(n, rng, 55, hit, 0.75, 400, 5000, decay=0.12))
    x = 0.8 * scrape + 0.3 * ticks + thump + 0.7 * body + 0.5 * crack + 0.6 * rubble
    return finish(reverb(x, size=1.3, fb=0.6, mix=0.2), fade_out=0.06)


def drip(v=0):
    rng = np.random.default_rng(2500 + v)
    n = secs(1.2)
    f0 = [1150, 1450, 900][v]
    drop = osc(glide(f0, f0 * 2.2, n, 0.014)) * env(n, 0.0005, 0.013)   # rising "plink"
    dry = drop + 0.3 * burst(n, rng, 0.0002, 0.001, "lp", 3000)
    delays = np.array([0.113, 0.161, 0.217, 0.271]) * (1 + 0.1 * v)
    wet = reverb(dry, fb=0.55, mix=1.0, damp=2200, delays=delays) - dry   # cave echoes only
    return finish(dry + 2.0 * wet, fade_out=0.15)


# ----------------------------------------------------------------------------- creatures

def whisper(v=0):
    rng = np.random.default_rng(2600 + v)
    n = secs(1.5)
    p = np.arange(n) / n

    def voice(shift):
        src = noise(n, rng)
        f1 = 500 + 350 * np.sin(TAU * (1.3 * p + shift)) ** 2        # drifting vowel formants
        f2 = 1300 + 600 * np.sin(TAU * (0.9 * p + shift + 0.2))
        f3 = 2600 + 300 * wobble(n, rng, 3)
        vowel = unit(formants(src, [(f1, 7, 1.0), (f2, 9, 0.7), (f3, 10, 0.35)]))
        sib = unit(svf(noise(n, rng) * rough(n, rng, 4) ** 3, 6000 + 1500 * wobble(n, rng, 3), q=2.5))
        return vowel * (0.3 + 0.7 * rough(n, rng, 7)) + 0.35 * sib

    swell = np.sin(np.pi * p ** 1.36) ** 2          # peaks around 0.9 s
    x = (voice(0.0) + 0.6 * voice(0.37)) * swell
    return finish(reverb(x, size=1.6, fb=0.75, mix=0.45, damp=5000), fade_out=0.1)


def creature_growl(v=0):
    rng = np.random.default_rng(2700 + v)
    n = secs(0.8)
    t = times(n)
    f0 = 68 * (1 + 0.25 * np.exp(-t / 0.1)) * (1 + 0.07 * wobble(n, rng, 6) + 0.025 * wobble(n, rng, 70))
    src = harmonic(f0, tilt=1.1, fmax=5000)
    gurgle = 0.25 + 0.75 * rough(n, rng, 28) ** 1.5
    tract = (biquad(src, "lp", 900, 0.9) + 0.8 * biquad(src, "bp", 380, 3.5)
             + 0.4 * svf(src, 750 + 250 * wobble(n, rng, 3), q=4))
    breath = unit(biquad(noise(n, rng), "lp", 700))
    amp = np.clip(t / 0.08, 0, 1) * np.clip((0.8 - t) / 0.25, 0, 1)
    body = np.tanh(2.5 * (unit(tract) + 0.25 * breath) * gurgle) * amp
    return finish(body + 0.3 * unit(bubbles(n, rng, 7, 0.05, 0.65, 150, 350)), fade_out=0.05)


def creature_hurt(v=0):
    rng = np.random.default_rng(2800 + v)
    n = secs(0.3)
    t = times(n)
    f0 = np.interp(t, [0, 0.05, 0.3], [900, 1650, 1050])
    f0 = f0 * (1 + 0.04 * np.sin(TAU * 28 * t) + 0.02 * wobble(n, rng, 90))
    src = harmonic(f0, tilt=0.9, fmax=12000)
    voice = biquad(src, "bp", 2300, 1.8) + 0.6 * biquad(src, "bp", 3600, 3) + 0.25 * src
    rasp = biquad(noise(n, rng), "bp", 3000, 1.0) * (0.5 + 0.5 * np.sin(TAU * np.cumsum(f0) / SR))
    amp = np.clip(t / 0.01, 0, 1) * np.exp(-np.maximum(t - 0.08, 0) / 0.07)
    return finish(np.tanh(2.0 * (unit(voice) + 0.3 * unit(rasp))) * amp)


def creature_die(v=0):
    rng = np.random.default_rng(2900 + v)
    n, start = secs(0.6), 0.06
    t = times(n)
    wet = biquad(noise(n, rng), "lp", 2000) * env(n, 0.002, 0.05)
    squelch = unit(svf(wet, np.interp(t, [0, 0.04, 0.15], [250, 1200, 300]), q=4))
    fall = np.clip((t - start) / 0.5, 0, 1)
    f0 = 1500 * (280 / 1500) ** fall * (1 + 0.05 * np.sin(TAU * 16 * t))
    src = harmonic(f0, tilt=0.9, fmax=10000)
    screech = np.tanh(1.8 * unit(biquad(src, "bp", 1800, 1.5) + 0.3 * src))
    amp = np.clip((t - start) / 0.02, 0, 1) * np.exp(-np.maximum(t - start - 0.1, 0) / 0.18)
    x = 0.9 * squelch + 0.4 * unit(bubbles(n, rng, 4, 0.0, 0.12, 200, 450)) + 0.8 * screech * amp
    return finish(x, fade_out=0.06)


# ----------------------------------------------------------------------------- ambience loops

LOOP = 12.0  # seconds


def per(f, T=LOOP):
    """Snap a frequency to a whole number of cycles per loop of T seconds."""
    return round(f * T) / T


def lfo(t, cycles, phase=0.0, T=LOOP):
    return np.sin(TAU * cycles * t / T + phase)


def band(fc, octaves):
    return lambda f: np.exp(-0.5 * (np.log2(np.maximum(f, 1e-3) / fc) / octaves) ** 2)


def lowband(fc):
    return lambda f: (f > 15) / (1 + (f / fc) ** 4)


def loop_noise(n, rng, shape):
    return unit(spectral(noise(n, rng), shape))


def loop_rough(n, rng, rate):
    """Periodic random amplitude flutter in [0, 1]."""
    return unit(np.abs(spectral(noise(n, rng), lambda f: 1 / (1 + (f / rate) ** 4))))


def loop_grains(n, rng, count, fmin, fmax, **kw):
    """grains() spread evenly over a loop; tails running past the end wrap to the start."""
    g = grains(2 * n, rng, count, 0.0, n / SR, fmin, fmax, decay=1e9, skew=1.0, **kw)
    return g[:n] + g[n:]


def bump(t, centre, width):
    """Smooth event envelope that wraps around the loop boundary."""
    d = (t - centre + LOOP / 2) % LOOP - LOOP / 2
    return np.where(np.abs(d) < width / 2, np.cos(np.pi * d / width) ** 2, 0.0)


def drone(t, rng, voices):
    """Detuned low sines [(freq, amp, lfo cycles)], each slowly wobbling in pitch and level."""
    out = np.zeros(len(t))
    for f, a, m in voices:
        ph = rng.uniform(0, TAU)
        out += a * np.sin(TAU * per(f) * t + ph + 0.2 * lfo(t, 1, ph)) * (0.65 + 0.35 * lfo(t, m, ph))
    return unit(out)


def finish_loop(x, peak_db=-12.0):
    x = spectral(x, lambda f: (f >= 20).astype(float))   # no DC / sub-sonic, still periodic
    return unit(x) * 10 ** (peak_db / 20)


def amb_cave(v=0):
    rng = np.random.default_rng(3000 + v)
    t = times(secs(LOOP))
    n = len(t)
    hum = drone(t, rng, [(41.25, 0.5, 1), (55.0, 1.0, 2), (55.333, 0.8, 3),
                         (82.5, 0.3, 1), (110.25, 0.12, 5), (164.917, 0.05, 2)])
    rumble = loop_noise(n, rng, lowband(120)) * (0.7 + 0.3 * lfo(t, 2, 1.0))
    air = loop_noise(n, rng, band(450, 0.8)) * (0.55 + 0.45 * lfo(t, 1, 2.0))
    wind = sum(loop_noise(n, rng, band(fc, 0.35)) * (0.5 + 0.5 * lfo(t, m, ph)) ** 3   # gusts
               for fc, m, ph in [(650, 2, 0.3), (1050, 3, 2.1), (1600, 5, 4.0)])
    return finish_loop(hum + 0.5 * rumble + 0.12 * air + 0.08 * unit(wind))


def amb_deep(v=0):
    rng = np.random.default_rng(3100 + v)
    t = times(secs(LOOP))
    n = len(t)
    hum = drone(t, rng, [(29.0, 1.0, 1), (29.25, 0.9, 2), (43.5, 0.5, 1),       # 0.25 / 0.33 Hz beats
                         (43.833, 0.45, 3), (58.083, 0.2, 2), (87.0, 0.07, 4)])
    eerie = sum(np.sin(TAU * per(f) * t) * (0.5 + 0.5 * lfo(t, m, ph)) ** 3      # faint tritone
                for f, m, ph in [(233.0, 1, 0.0), (233.5, 2, 1.0), (329.5, 1, 3.0)])
    sub = loop_noise(n, rng, lowband(70)) * (0.6 + 0.4 * lfo(t, 3, 0.5))
    rumble_env = sum(a * bump(t, c, w) for c, w, a in [(2.0, 3.0, 1.0), (6.7, 2.2, 0.6), (9.8, 3.5, 0.8)])
    rumble = (loop_noise(n, rng, band(55, 0.7)) + 0.4 * loop_noise(n, rng, band(160, 0.6))) * rumble_env
    breath = loop_noise(n, rng, band(300, 0.5)) * (0.5 + 0.5 * lfo(t, 2, 0.7)) ** 4
    return finish_loop(hum + 0.35 * sub + 0.6 * unit(rumble) + 0.04 * unit(eerie) + 0.06 * breath)


# ----------------------------------------------------------------------------- drilling machine

DRILL_LOOP = 4.0  # seconds


def drill_motor(t, rng, f0, fire, whine, T=DRILL_LOOP):
    """Periodic engine hum: buzzy harmonics of f0, diesel knock at `fire` Hz, electric whine."""
    n = len(t)
    f0, fire, whine = per(f0, T), per(fire, T), per(whine, T)
    phase = TAU * f0 * t + 0.15 * lfo(t, 1, 0.0, T)
    hum = sum(np.sin(k * phase) / k ** 1.1 for k in range(1, int(2500 / f0) + 1))
    knock = (0.5 + 0.5 * np.cos(TAU * fire * t)) ** 6                 # firing pulses
    hum = spectral(hum * (0.6 + 0.4 * knock), lowband(700))            # muffled by the hull
    clatter = loop_noise(n, rng, band(1500, 0.7)) * knock ** 2         # valves / tappets
    tone = (np.sin(TAU * whine * t) + 0.3 * np.sin(TAU * 2 * whine * t)) * (0.8 + 0.2 * lfo(t, 2, 1.0, T))
    return unit(hum) + 0.12 * clatter + 0.05 * tone


def drill_loop(v=0):
    rng = np.random.default_rng(3200 + v)
    T = DRILL_LOOP
    t = times(secs(T))
    n = len(t)
    motor = drill_motor(t, rng, 46, 23, 740)
    ph = (per(7, T) * t + 0.5) % 1.0                                   # 7 Hz grinding chug
    chug = (1 - np.exp(-ph / 0.004)) * np.exp(-ph / 0.05)
    chug *= 0.75 + 0.25 * lfo(t, 3, 0.4, T) * lfo(t, 5, 1.3, T)        # no two chugs alike
    grind = loop_noise(n, rng, band(380, 0.7)) * chug
    thump = np.sin(TAU * per(55, T) * t) * chug ** 2
    crunch = loop_noise(n, rng, band(2600, 0.9)) * (0.35 + 0.65 * chug) * loop_rough(n, rng, 40)
    grit = loop_grains(n, rng, 240, 1500, 7000, length=(0.001, 0.004))
    x = motor + 0.7 * unit(grind) + 0.6 * thump + 0.35 * unit(crunch) + 0.25 * unit(grit)
    return finish_loop(x, -10.0)


def drill_idle(v=0):
    rng = np.random.default_rng(3300 + v)
    t = times(secs(DRILL_LOOP))
    rumble = loop_noise(len(t), rng, band(120, 0.6))
    return finish_loop(drill_motor(t, rng, 30, 15, 420) + 0.2 * rumble, -16.0)


def engine(f0):
    """One-shot engine hum for a per-sample f0 (Hz), with firing knock at half that rate."""
    knock = (0.5 + 0.5 * np.cos(TAU * np.cumsum(f0 / 2) / SR)) ** 6
    return unit(biquad(harmonic(f0, tilt=1.1, fmax=2500) * (0.5 + 0.5 * knock), "lp", 700)), knock


def cough(n, rng, t0):
    """Engine misfire: dull pop of exhaust."""
    m = n - secs(t0)
    pop = place(n, t0, osc(glide(110, 50, m, 0.04)) * env(m, 0.002, 0.04))
    return burst(n, rng, 0.002, 0.04, "lp", 500, delay=t0) + 0.7 * pop


def drill_stall(v=0):
    rng = np.random.default_rng(3400 + v)
    n = secs(1.2)
    t = times(n)
    rpm = np.clip(1 - (t / 1.0) ** 1.6, 0, 1)
    coughs = np.zeros(n)
    for c, depth in [(0.18, 0.5), (0.42, 0.6), (0.63, 0.5), (0.8, 0.4)]:  # stumble, catch, stumble...
        rpm *= 1 - depth * np.exp(-((t - c) / 0.035) ** 2)
        coughs += cough(n, rng, c + 0.02)
    hum, knock = engine(12 + 34 * rpm)
    sputter = biquad(noise(n, rng), "bp", 1500, 0.8) * knock ** 2 * rpm
    m = n - secs(1.02)
    clunk = place(n, 1.02, modes(m, [180, 420, 760], [0.05, 0.03, 0.02], [1.0, 0.5, 0.3]))
    clunk += 0.5 * burst(n, rng, 0.001, 0.02, "lp", 800, delay=1.02)
    x = hum * rpm ** 0.8 + 0.15 * unit(sputter) + 0.6 * unit(coughs) + 0.4 * clunk
    return finish(x, fade_out=0.1)


def drill_start(v=0):
    rng = np.random.default_rng(3500 + v)
    n, catch = secs(1.0), 0.42
    t = times(n)
    comp = (0.5 + 0.5 * np.cos(TAU * 5.5 * t + np.pi)) ** 4            # compression strokes
    starter = biquad(harmonic(190 * (1 + 0.35 * np.sin(TAU * 5.5 * t)), tilt=1.0, fmax=4000), "bp", 900, 0.8)
    starter = unit(starter) * (0.6 + 0.4 * comp) * np.clip(t / 0.02, 0, 1) * np.clip((catch + 0.06 - t) / 0.05, 0, 1)
    churn = unit(biquad(noise(n, rng), "lp", 300)) * comp * (t < catch + 0.05)
    e = np.maximum(t - catch, 0)
    hum, _ = engine(14 + 32 * (1 - np.exp(-e / 0.22)))
    hum *= np.clip(e / 0.03, 0, 1) * (0.6 + 0.4 * (1 - np.exp(-e / 0.25)))
    whine = osc(200 * (740 / 200) ** np.clip(e / 0.5, 0, 1)) * np.clip(e / 0.1, 0, 1)
    x = 0.5 * starter + 0.3 * churn + hum + 0.6 * unit(cough(n, rng, catch)) + 0.06 * whine
    return finish(x, fade_out=0.08)


def alarm(v=0):
    n = secs(0.9)
    x = np.zeros(n)
    m = secs(0.38)
    tm = times(m)
    for t0, f in [(0.0, 660.0), (0.42, 495.0)]:
        f0 = f * (0.97 + 0.03 * (1 - np.exp(-tm / 0.03)))              # slight upward scoop
        tone = harmonic(f0, tilt=0.7, fmax=9000) + harmonic(f0 * 1.012, tilt=0.7, fmax=9000)
        horn = np.tanh(3 * unit(biquad(tone, "bp", 1400, 1.2) + 0.5 * tone))
        x += place(n, t0, horn * np.clip(tm / 0.01, 0, 1) * np.clip((0.38 - tm) / 0.02, 0, 1))
    return finish(reverb(x, size=1.2, fb=0.6, mix=0.2), fade_out=0.04)


def hull_hit(v=0):
    rng = np.random.default_rng(3600 + v)
    n = secs(0.7)
    ratios = np.array([1, 1.59, 2.14, 2.30, 2.65, 2.92, 3.16, 3.50, 4.06, 5.20]) * (1 + rng.uniform(-0.01, 0.01, 10))
    f, decays = 95 * ratios, np.linspace(0.45, 0.12, 10)               # thick plate modes
    amps = np.array([1, 0.8, 0.7, 0.6, 0.5, 0.5, 0.4, 0.35, 0.3, 0.2])
    clang = unit(modes(n, f, decays, amps) + modes(n, f * 1.004 + 0.7, decays, 0.5 * amps))
    boom = osc(glide(75, 38, n, 0.12)) * env(n, 0.002, 0.15)
    impact = burst(n, rng, 0.0005, 0.02, "lp", 2500)
    rattle = grains(n, rng, 40, 0.03, 0.5, 2000, 7000, length=(0.001, 0.004), decay=0.2, q=6)
    pings = sum(modes(n, [rng.uniform(1800, 4500)], [0.02], [rng.uniform(0.3, 1.0)], delay=rng.uniform(0.04, 0.45))
                for _ in range(10))                                    # loose bolts, fittings
    x = np.tanh(1.3 * (0.8 * clang + boom + 0.6 * impact)) + 0.25 * unit(rattle) + 0.2 * unit(pings)
    return finish(reverb(x, size=1.4, fb=0.65, mix=0.25), fade_out=0.12)


def breach(v=0):
    rng = np.random.default_rng(3700 + v)
    n = secs(1.0)
    t = times(n)
    clicks, tc = np.zeros(n), 0.02                                     # stick-slip creak
    while tc < 0.6:
        clicks[secs(tc)] += rng.uniform(0.5, 1.0)
        tc += 1 / ((50 + 120 * tc / 0.6) * rng.uniform(0.6, 1.4))
    slide = (1 + 0.25 * t) * (1 + 0.05 * wobble(n, rng, 6))
    creak = formants(clicks, [(700 * slide, 14, 1.0), (1650 * slide, 16, 0.7), (2900 * slide, 18, 0.4)])
    tear_amp = rough(n, rng, 80) ** 2 * np.clip(t / 0.05, 0, 1) * np.clip((0.5 - t) / 0.1, 0, 1)
    tear = biquad(noise(n, rng) * tear_amp, "bp", 2400, 0.9)
    bang = osc(glide(90, 45, n, 0.08)) * env(n, 0.002, 0.08) + 0.5 * burst(n, rng, 0.0005, 0.03, "lp", 1500)
    hiss_amp = np.clip((t - 0.3) / 0.08, 0, 1) * (0.85 + 0.15 * wobble(n, rng, 12))
    hiss = biquad(biquad(noise(n, rng), "hp", 3000), "bp", 6000, 0.7) * hiss_amp
    x = 0.7 * unit(creak) + 0.5 * unit(tear) + 0.6 * unit(bang) + 0.35 * unit(hiss)
    return finish(reverb(x, size=1.3, fb=0.6, mix=0.2), fade_out=0.15)


def repair(v=0):
    rng = np.random.default_rng(3800 + v)
    n = secs(0.6)
    x = np.zeros(n)
    for t0, f, a in [(0.0, 1900, 1.0), (0.3, 2150, 0.85)]:             # wrench clanks
        x += a * modes(n, f * np.array([1, 1.48, 2.31, 3.1]), [0.07, 0.05, 0.035, 0.02], [1, 0.6, 0.45, 0.3], delay=t0)
        x += 0.5 * a * burst(n, rng, 0.0003, 0.003, "hp", 2500, delay=t0)
    for start in (0.08, 0.38):                                         # ratchet clicks
        for i in range(6):
            tc = start + i * 0.024 * (1 + rng.uniform(-0.1, 0.1))
            x += 0.35 * (burst(n, rng, 0.0002, 0.0008, "hp", 3000, delay=tc)
                         + modes(n, [3300, 5200], [0.004, 0.003], [1.0, 0.5], delay=tc))
    return finish(reverb(x, mix=0.2), fade_out=0.06)


def furnace(v=0):
    rng = np.random.default_rng(3900 + v)
    n = secs(0.8)
    t = times(n)
    scrape = biquad(noise(n, rng) * env(n, 0.02, 0.04) * rough(n, rng, 60), "bp", 1800, 1.0)  # shovel
    coal = grains(n, rng, 40, 0.06, 0.3, 300, 3000, length=(0.003, 0.012), decay=0.15, q=3)
    clatter = grains(n, rng, 25, 0.06, 0.3, 2000, 6000, length=(0.001, 0.004), decay=0.15)
    whoosh_amp = np.clip((t - 0.12) / 0.15, 0, 1) ** 2 * np.exp(-np.maximum(t - 0.35, 0) / 0.3)
    cutoff = 200 + 1400 * np.exp(-((t - 0.32) / 0.12) ** 2) + 400 * np.clip((t - 0.32) / 0.4, 0, 1)
    whoosh = svf(noise(n, rng) * whoosh_amp, cutoff, q=0.9, mode="lp")   # fire catches
    roar = biquad(noise(n, rng), "lp", 150) * whoosh_amp
    crackle = grains(n, rng, 22, 0.2, 0.78, 2500, 8000, length=(0.0005, 0.0015), decay=10, q=0.7, skew=1.0)
    x = (0.4 * unit(scrape) + 0.5 * unit(coal) + 0.25 * unit(clatter) + 0.8 * unit(whoosh)
         + 0.3 * unit(roar) + 0.45 * unit(crackle))
    return finish(x, fade_out=0.12)


def lever(v=0):
    rng = np.random.default_rng(4000 + v)
    n, hit = secs(0.25), 0.05
    latch = 0.4 * burst(n, rng, 0.0002, 0.001, "hp", 3000) + 0.3 * modes(n, [2600, 3900], [0.006, 0.004], [1.0, 0.5])
    m = n - secs(hit)
    thump = place(n, hit, osc(glide(160, 85, m, 0.04)) * env(m, 0.001, 0.04))
    body = unit(modes(n, [420, 980, 1650, 2400], [0.06, 0.04, 0.03, 0.02], [1, 0.6, 0.4, 0.25], delay=hit))
    knock = burst(n, rng, 0.0005, 0.008, "bp", 1200, 1.0, delay=hit)
    rattle = unit(grains(n, rng, 6, hit + 0.01, 0.18, 1500, 5000, length=(0.001, 0.003), decay=0.06, q=4))
    return finish(latch + thump + 0.5 * body + 0.5 * knock + 0.15 * rattle, fade_out=0.04)


# ----------------------------------------------------------------------------- turret / sonar

def sonar_ping(v=0):
    rng = np.random.default_rng(4100 + v)
    n = secs(1.6)
    f = glide(1200, 1185, n, 1.2)                                      # sags a touch: eerie
    tone = osc(f) + 0.35 * osc(f * 1.0025) + 0.08 * osc(2 * f)        # slow beating shimmer
    ping = tone * env(n, 0.003, 0.25)
    m = n - secs(0.7)
    echo = place(n, 0.7, biquad(osc(f[:m] * 0.99) * env(m, 0.01, 0.2), "lp", 2000))
    x = ping + 0.3 * echo + 0.02 * burst(n, rng, 0.0005, 0.004, "lp", 4000)
    return finish(reverb(x, size=2.0, fb=0.8, mix=0.4, damp=3000), fade_out=0.25)


def turret_fire(v=0):
    rng = np.random.default_rng(4200 + v)
    n, p = secs(0.5), 1 + 0.06 * (v - 1)
    thump = osc(glide(120 * p, 45 * p, n, 0.06)) * env(n, 0.001, 0.08)
    blast = burst(n, rng, 0.001, 0.04, "lp", 400 * p)
    air = burst(n, rng, 0.002, 0.07, "bp", 900 * p, 0.6)                # pneumatic "pfff"
    clack = unit(modes(n, np.array([1100, 1850, 2700, 3900]) * p * (1 + rng.uniform(-0.03, 0.03, 4)),
                       [0.06, 0.045, 0.035, 0.025], [1.0, 0.7, 0.5, 0.3], delay=0.005))
    reload = unit(modes(n, np.array([1700, 2900, 4300]) * p, [0.03, 0.02, 0.015], [1.0, 0.6, 0.4],
                        delay=0.17 + rng.uniform(0, 0.03)))
    whoosh = unit(svf(noise(n, rng) * env(n, 0.01, 0.07, delay=0.02), glide(3000, 600, n, 0.25), q=1.5))
    x = np.tanh(1.6 * (thump + 0.6 * blast + 0.35 * air + 0.5 * clack)) + 0.25 * reload + 0.35 * whoosh
    return finish(x, fade_out=0.06)


def turret_turn(v=0):
    rng = np.random.default_rng(4300 + v)
    T = 1.0
    t = times(secs(T))
    n = len(t)
    phase = TAU * per(880, T) * t + 0.6 * lfo(t, 2, 0.0, T)            # servo whine, gently wavering
    whine = np.sin(phase) + 0.3 * np.sin(2 * phase) + 0.12 * np.sin(3 * phase)
    teeth = (0.5 + 0.5 * np.cos(TAU * per(43, T) * t)) ** 3             # gear mesh
    gears = loop_noise(n, rng, band(2500, 0.6)) * teeth
    hum = np.sin(TAU * per(120, T) * t) + 0.4 * np.sin(TAU * per(240, T) * t)
    x = 0.5 * whine * (0.85 + 0.15 * lfo(t, 3, 1.0, T)) + 0.35 * gears + 0.3 * hum
    return finish_loop(x, -18.0)


def bolt_hit(v=0):
    rng = np.random.default_rng(4400 + v)
    n = secs(0.4)
    crack = burst(n, rng, 0.0005, 0.012, "bp", 2200, 0.8)
    thump = osc(glide(140, 60, n, 0.05)) * env(n, 0.001, 0.05)
    debris = unit(grains(n, rng, 35, 0.005, 0.3, 500, 5000, decay=0.1))
    f = rng.uniform(3000, 3500)
    ping = osc(glide(f, f * 0.8, n, 0.2)) * env(n, 0.002, 0.12, delay=0.012)  # ricochet whine
    ping += 0.3 * osc(glide(2.7 * f, 2.7 * f * 0.8, n, 0.2)) * env(n, 0.002, 0.05, delay=0.012)
    x = 0.8 * crack + 0.7 * thump + 0.5 * debris + 0.3 * ping
    return finish(reverb(x, mix=0.15), fade_out=0.06)


# ----------------------------------------------------------------------------- the worm

def worm_voice(f0, rng, fmax=1500.0):
    """Huge gravelly voice: buzzy harmonics with vocal-fry flutter through low, wobbly formants."""
    n = len(f0)
    src = harmonic(f0, tilt=0.9, fmax=fmax) * (0.35 + 0.65 * rough(n, rng, 35))
    return unit(formants(src, [(250 * (1 + 0.15 * wobble(n, rng, 2)), 3, 1.0),
                               (520 * (1 + 0.2 * wobble(n, rng, 2)), 4, 0.6), (900, 5, 0.25)]))


def heavy_impact(n, rng, t0, amp=1.0):
    """Massive body hitting rock: sub thump, dull slap, rubble."""
    m = n - secs(t0)
    thump = place(n, t0, osc(glide(80, 35, m, 0.1)) * env(m, 0.003, 0.12))
    slap = burst(n, rng, 0.002, 0.05, "lp", 400, delay=t0)
    rubble = unit(grains(n, rng, 20, t0 + 0.01, t0 + 0.4, 300, 3000, decay=0.15))
    return amp * (thump + 0.6 * slap + 0.3 * rubble)


def worm_roar(v=0):
    rng = np.random.default_rng(4500 + v)
    n = secs(2.0)
    t = times(n)
    f0 = np.interp(t, [0, 0.6, 2.0], [32, 45, 30]) * (1 + 0.1 * wobble(n, rng, 3) + 0.04 * wobble(n, rng, 40))
    voice = worm_voice(f0, rng)
    grind = unit(biquad(noise(n, rng) * rough(n, rng, 18), "bp", 600, 0.8))
    gravel = unit(grains(n, rng, 160, 0.1, 1.8, 300, 2500, decay=1e9, skew=1.0))
    amp = np.clip(t / 0.25, 0, 1) * np.clip((2.0 - t) / 0.6, 0, 1)
    x = (np.tanh(2.0 * voice) + 0.3 * grind + 0.25 * gravel) * amp
    x = biquad(biquad(x, "lp", 900), "lp", 900)                         # heard through rock
    return finish(reverb(x, size=2.0, fb=0.75, mix=0.3, damp=800), fade_out=0.15)


def worm_burrow(v=0):
    rng = np.random.default_rng(4600 + v)
    T = 3.0
    t = times(secs(T))
    n = len(t)
    heave = (0.5 + 0.5 * np.cos(TAU * per(4 / 3, T) * t)) ** 2         # 4 peristaltic pushes per loop
    heave *= 0.8 + 0.2 * lfo(t, 1, 0.5, T)
    rumble = loop_noise(n, rng, lowband(90)) * (0.5 + 0.5 * heave)
    drone = np.sin(TAU * per(31, T) * t) + 0.6 * np.sin(TAU * per(46.33, T) * t + 0.4 * lfo(t, 1, 0.0, T))
    grind = loop_noise(n, rng, band(500, 0.7)) * loop_rough(n, rng, 12) * heave
    gravel = loop_grains(n, rng, 300, 300, 4000) * (0.3 + 0.7 * heave) * loop_rough(n, rng, 25)
    x = unit(rumble) + 0.4 * drone * (0.6 + 0.4 * heave) + 0.4 * unit(grind) + 0.35 * unit(gravel)
    return finish_loop(spectral(x, lowband(2500)), -12.0)


def worm_hit(v=0):
    rng = np.random.default_rng(4700 + v)
    n = secs(0.6)
    t = times(n)
    thump = osc(glide(90, 35, n, 0.08)) * env(n, 0.002, 0.1)
    wet = biquad(noise(n, rng), "lp", 1500) * env(n, 0.002, 0.06)
    splat = unit(svf(wet, np.interp(t, [0, 0.04, 0.2], [300, 1500, 250]), q=3))
    blobs = unit(bubbles(n, rng, 5, 0.01, 0.2, 80, 200))
    f0 = glide(55, 40, n, 0.5) * (1 + 0.05 * np.sin(TAU * 5 * t))
    groan = worm_voice(f0, rng, fmax=2000) * env(n, 0.05, 0.25, delay=0.06)
    x = np.tanh(1.5 * (thump + 0.6 * splat + 0.3 * blobs + 0.8 * groan))
    return finish(biquad(x, "lp", 1500), fade_out=0.08)


def worm_die(v=0):
    rng = np.random.default_rng(4800 + v)
    n = secs(2.5)
    t = times(n)
    f0 = glide(50, 22, n, 2.0) * (1 + 0.08 * wobble(n, rng, 4))
    groan = np.tanh(2.0 * worm_voice(f0, rng)) * np.clip(t / 0.1, 0, 1) * np.exp(-np.maximum(t - 0.6, 0) / 0.6)
    thrash = sum(heavy_impact(n, rng, t0, a) for t0, a in
                 [(0.3, 1.0), (0.65, 0.8), (0.9, 0.9), (1.25, 0.6), (1.6, 0.45)])
    settle = unit(grains(n, rng, 40, 1.6, 2.4, 400, 4000, decay=0.5)) * 0.25
    x = biquad(0.8 * groan + unit(thrash) + settle, "lp", 2500)
    return finish(reverb(x, size=2.0, fb=0.7, mix=0.25, damp=1500), fade_out=0.2)


def rumble(v=0):
    rng = np.random.default_rng(4900 + v)
    n = secs(2.5)
    p = np.arange(n) / n
    swell = np.sin(np.pi * p ** 1.2) ** 2                               # builds to ~1.4 s, then ebbs
    quake = unit(biquad(biquad(noise(n, rng), "lp", 80), "lp", 80)) + 0.5 * unit(biquad(noise(n, rng), "bp", 40, 1.0))
    sub = osc(28, n) * rough(n, rng, 4)
    rattles = unit(grains(n, rng, 60, 0.2, 2.3, 2000, 6000, length=(0.001, 0.003), decay=1e9, skew=1.0, q=4))
    pebbles = unit(grains(n, rng, 25, 0.3, 2.2, 600, 2500, decay=1e9, skew=1.0))
    x = (unit(quake) + 0.4 * sub) * swell + (0.12 * rattles + 0.12 * pebbles) * swell ** 1.5
    return finish(x, fade_out=0.2)


# ----------------------------------------------------------------------------- table / main

def variants(name, fn, count):
    return {f"{name}_v{i + 1}": (lambda i=i: fn(i)) for i in range(count)}


SOUNDS = {
    **variants("hit_dirt", hit_dirt, 3),
    **variants("hit_stone", hit_stone, 3),
    **variants("hit_hard", hit_hard, 3),
    "bonk": bonk,
    **variants("break", rock_break, 2),
    "swing": swing,
    **variants("step", step, 4),
    "land": land,
    "jump": jump,
    "ore": ore,
    "coins": coins,
    "ui_click": ui_click,
    "rope": rope,
    "rockfall": rockfall,
    **variants("drip", drip, 3),
    "whisper": whisper,
    "creature_growl": creature_growl,
    "creature_hurt": creature_hurt,
    "creature_die": creature_die,
    "player_hurt": player_hurt,
    "amb_cave": amb_cave,
    "amb_deep": amb_deep,
    "drill_loop": drill_loop,
    "drill_idle": drill_idle,
    "drill_stall": drill_stall,
    "drill_start": drill_start,
    "alarm": alarm,
    "hull_hit": hull_hit,
    "breach": breach,
    "repair": repair,
    "furnace": furnace,
    "lever": lever,
    "sonar_ping": sonar_ping,
    **variants("turret_fire", turret_fire, 3),
    "turret_turn": turret_turn,
    **variants("bolt_hit", bolt_hit, 2),
    "worm_roar": worm_roar,
    "worm_burrow": worm_burrow,
    "worm_hit": worm_hit,
    "worm_die": worm_die,
    "rumble": rumble,
}


def write_wav(path, x):
    data = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in SOUNDS.items():
        x = np.asarray(fn(), float)
        assert np.all(np.isfinite(x)), f"{name}: non-finite samples"
        write_wav(os.path.join(OUT, name + ".wav"), x)
        peak = 20 * np.log10(np.max(np.abs(x)))
        print(f"{name + '.wav':22s} {len(x) / SR:6.3f} s  peak {peak:6.2f} dBFS")


if __name__ == "__main__":
    main()
