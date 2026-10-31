#!/usr/bin/env python3
"""Synthesizes every sound effect of the game into assets/sfx/ (16-bit mono 44.1 kHz WAV).

Pure numpy (scipy.signal.lfilter is used only to speed up filtering if installed).
Fixed seeds, so every run writes identical files. One-shots get a short fade in/out
and are peak-normalized to -3 dBFS; the two ambience loops are built periodic (every
sine, LFO and noise spectrum has a whole number of cycles per loop), so they loop
seamlessly, and are normalized to -12 dBFS.

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


def grains(n, rng, count, t0, t1, fmin, fmax, length=(0.002, 0.008), decay=0.1, q=1.5):
    """Scatter of tiny filtered noise ticks (gravel, crumbs, debris), denser and louder early."""
    out = np.zeros(n)
    for _ in range(count):
        start = t0 + (t1 - t0) * rng.random() ** 1.7
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


def per(f):
    """Snap a frequency to a whole number of cycles per loop."""
    return round(f * LOOP) / LOOP


def lfo(t, cycles, phase=0.0):
    return np.sin(TAU * cycles * t / LOOP + phase)


def band(fc, octaves):
    return lambda f: np.exp(-0.5 * (np.log2(np.maximum(f, 1e-3) / fc) / octaves) ** 2)


def lowband(fc):
    return lambda f: (f > 15) / (1 + (f / fc) ** 4)


def loop_noise(n, rng, shape):
    return unit(spectral(noise(n, rng), shape))


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
