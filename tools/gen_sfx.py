#!/usr/bin/env python3
"""Synthesizes every sound effect of the game into assets/sfx/ (16-bit mono 44.1 kHz WAV).

Pure numpy (scipy.signal.lfilter is used only to speed up filtering if installed).
Fixed seeds, so every run writes identical files. One-shots get a short fade in/out
and are peak-normalized to -3 dBFS. Loops (amb_*, drill_loop, drill_idle, turret_turn,
worm_burrow, bat_flap, lava_bubble, music_* except music_ending, gas_hiss, water_leak, pump, vein_pulse) are built periodic: every sine, LFO and
noise spectrum has a whole number of cycles per loop, events near the end wrap round
to the start, and reverb runs in steady state, so they loop seamlessly. Each loop is
normalized to its own quieter peak (see the finish_loop() call in its function).

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


def fold(x, n):
    """Wrap a buffer longer than the loop back onto it (events near the end ring on into the start)."""
    out = np.zeros(n)
    for i in range(0, len(x), n):
        seg = x[i:i + n]
        out[:len(seg)] += seg
    return out


def periodic(x, effect):
    """Run a non-circular effect (reverb, IIR filter) on a loop in steady state:
    process three copies back to back and keep the last one."""
    n = len(x)
    return effect(np.tile(x, 3))[2 * n:]


def bump(t, centre, width, T=LOOP):
    """Smooth event envelope that wraps around the loop boundary."""
    d = (t - centre + T / 2) % T - T / 2
    return np.where(np.abs(d) < width / 2, np.cos(np.pi * d / width) ** 2, 0.0)


def drone(t, rng, voices, T=LOOP):
    """Detuned low sines [(freq, amp, lfo cycles)], each slowly wobbling in pitch and level."""
    out = np.zeros(len(t))
    for f, a, m in voices:
        ph = rng.uniform(0, TAU)
        out += a * np.sin(TAU * per(f, T) * t + ph + 0.2 * lfo(t, 1, ph, T)) * (0.65 + 0.35 * lfo(t, m, ph, T))
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


# ----------------------------------------------------------------------------- bats / crystals / lava

def pings(n, rng, count, t0, t1, fmin, fmax, decay=(0.01, 0.03), fade=1e9, skew=1.0):
    """Little glassy tinks: a decaying partial plus a faint inharmonic overtone (kept below Nyquist)."""
    out = np.zeros(n)
    for _ in range(count):
        tc = t0 + (t1 - t0) * rng.random() ** skew
        f = np.exp(rng.uniform(np.log(fmin), np.log(fmax)))
        d = rng.uniform(*decay)
        a = rng.uniform(0.3, 1.0) * np.exp(-(tc - t0) / fade)
        fs, ds, amps = [f, 2.7 * f], [d, 0.4 * d], [a, 0.3 * a]
        keep = [i for i in range(2) if fs[i] < 18000]
        out += modes(n, [fs[i] for i in keep], [ds[i] for i in keep], [amps[i] for i in keep], delay=tc)
    return out


def bat_screech(v=0):
    rng = np.random.default_rng(5000 + v)
    n = secs(0.35)
    t = times(n)
    chitter, tc, m = np.zeros(n), 0.0, secs(0.018)
    while tc < 0.22:                                                   # fast downward chirps
        f = rng.uniform(4000, 8000)
        chirp = osc(glide(f, 0.65 * f, m, 0.015)) * env(m, 0.001, 0.005)
        chirp += 0.3 * osc(glide(2 * f, 1.3 * f, m, 0.015)) * env(m, 0.001, 0.003)
        chitter += rng.uniform(0.4, 1.0) * place(n, tc, chirp)
        tc += rng.uniform(0.018, 0.04)
    f0 = np.interp(t, [0, 0.08, 0.35], [2600, 3400, 2400]) * (1 + 0.15 * (v - 1))
    f0 = f0 * (1 + 0.06 * np.sin(TAU * 55 * t) + 0.03 * wobble(n, rng, 120))
    screech = biquad(harmonic(f0, tilt=0.8, fmax=14000), "bp", 5000, 1.2)
    screech = np.tanh(2 * unit(screech)) * np.clip((t - 0.06) / 0.01, 0, 1) * np.exp(-np.maximum(t - 0.12, 0) / 0.06)
    return finish(biquad(0.7 * unit(chitter) + 0.6 * screech, "hp", 1500), fade_out=0.04)


def bat_flap(v=0):
    rng = np.random.default_rng(5100 + v)
    T = 0.6
    n = secs(T)
    buf, m = np.zeros(2 * n), secs(0.04)
    for _ in range(9):                                                 # nine wings, each its own rate
        rate = per(rng.uniform(8, 15), T)
        phase, fc, a = rng.uniform(0, 1 / rate), rng.uniform(500, 1600), rng.uniform(0.4, 1.0)
        for k in range(int(round(rate * T))):
            tk = phase + k / rate + rng.uniform(-0.003, 0.003)
            down = biquad(noise(m, rng) * env(m, 0.004, 0.012), "bp", fc * rng.uniform(0.9, 1.1), 0.8)
            up = biquad(noise(m, rng) * env(m, 0.003, 0.006), "bp", 1.8 * fc, 1.0)
            snap = biquad(noise(m, rng) * env(m, 0.0003, 0.001), "hp", 3000)
            buf += a * (place(2 * n, tk, down + 0.25 * snap) + 0.4 * place(2 * n, tk + 0.5 / rate, up))
    return finish_loop(fold(buf, n), -14.0)


def crystal_hit(v=0):
    rng = np.random.default_rng(5200 + v)
    n = secs(0.6)
    f = [1760, 1980, 2350][v] * np.array([1, 1.5, 2.76, 3.9, 5.4]) * (1 + rng.uniform(-0.01, 0.01, 5))
    decays, amps = [0.45, 0.3, 0.22, 0.14, 0.08], np.array([1, 0.5, 0.6, 0.35, 0.25])
    chime = unit(modes(n, f, decays, amps) + modes(n, f * 1.004, decays, 0.6 * amps))  # twins shimmer
    crack = burst(n, rng, 0.0002, 0.003, "hp", 3000)
    shards = unit(grains(n, rng, 12, 0.0, 0.06, 4000, 10000, length=(0.0005, 0.002), decay=0.03, q=3))
    sparkle = unit(pings(n, rng, 12, 0.02, 0.4, 6000, 11000, decay=(0.015, 0.025), fade=0.2))
    tap = osc(glide(400, 250, n, 0.02)) * env(n, 0.001, 0.015)
    x = 0.7 * chime + 0.7 * crack + 0.3 * shards + 0.2 * sparkle + 0.2 * tap
    return finish(reverb(x, size=1.2, fb=0.7, mix=0.3, damp=8000), fade_out=0.12)


def crystal_break(v=0):
    rng = np.random.default_rng(5300 + v)
    n = secs(0.8)
    crack = burst(n, rng, 0.0003, 0.01, "hp", 2000) + 0.6 * burst(n, rng, 0.0005, 0.03, "bp", 3500, 0.8)
    shards = unit(pings(n, rng, 60, 0.0, 0.6, 3000, 11000, decay=(0.02, 0.08), fade=0.25, skew=1.6))
    chunks = unit(pings(n, rng, 10, 0.0, 0.3, 1400, 3000, decay=(0.08, 0.2), fade=0.2, skew=1.3))
    grit = unit(grains(n, rng, 40, 0.0, 0.5, 3000, 9000, length=(0.0005, 0.002), decay=0.2))
    thud = osc(glide(200, 120, n, 0.03)) * env(n, 0.001, 0.03)
    x = 0.8 * unit(crack) + 0.7 * shards + 0.5 * chunks + 0.25 * grit + 0.2 * thud
    return finish(reverb(x, size=1.2, fb=0.7, mix=0.3, damp=8000), fade_out=0.15)


def lava_bubble(v=0):
    rng = np.random.default_rng(5400 + v)
    T = 3.0
    t = times(secs(T))
    n = len(t)
    buf = np.zeros(2 * n)
    for _ in range(26):                                                # bubbles swell, then pop
        t0, f, L = rng.uniform(0, T), rng.uniform(60, 180), rng.uniform(0.05, 0.12)
        m = secs(L + 0.05)
        tm = times(m)
        blorp = osc(glide(f, 1.8 * f, m, L)) * np.clip(tm / L, 0, 1) ** 1.5 * np.clip((L + 0.005 - tm) / 0.005, 0, 1)
        pop = burst(m, rng, 0.0005, 0.006, "bp", rng.uniform(800, 2000), 0.8, delay=L)
        buf += rng.uniform(0.4, 1.0) * place(2 * n, t0, 0.8 * blorp + 0.5 * pop)
    rumble = loop_noise(n, rng, lowband(60)) * (0.7 + 0.3 * lfo(t, 2, 0.0, T))
    hiss = loop_noise(n, rng, band(5000, 1.0)) * (0.6 + 0.4 * loop_rough(n, rng, 3))
    goop = loop_noise(n, rng, band(250, 0.5)) * loop_rough(n, rng, 6)  # thick churning
    return finish_loop(unit(fold(buf, n)) + 0.35 * rumble + 0.06 * hiss + 0.2 * goop, -14.0)


def sizzle(v=0):
    rng = np.random.default_rng(5500 + v)
    n = secs(0.5)
    t = times(n)
    amp = np.clip(t / 0.01, 0, 1) * np.exp(-t / 0.18) * (0.6 + 0.4 * rough(n, rng, 30))
    hiss = biquad(biquad(noise(n, rng) * amp, "hp", 2500), "bp", 6000, 0.6)
    fry = grains(n, rng, 80, 0.0, 0.4, 2500, 9000, length=(0.0005, 0.002), decay=0.15, q=1.0)
    tss = burst(n, rng, 0.001, 0.02, "bp", 4000, 0.8)
    return finish(unit(hiss) + 0.5 * unit(fry) + 0.3 * tss, fade_out=0.08)


def steam_vent(v=0):
    rng = np.random.default_rng(5600 + v)
    n = secs(1.2)
    t = times(n)
    amp = np.clip(t / 0.02, 0, 1) * (1 - 0.3 * np.clip((t - 0.1) / 0.6, 0, 1)) * np.exp(-np.maximum(t - 0.7, 0) / 0.15)
    src = noise(n, rng)
    hiss = biquad(src, "hp", 1500) + 0.7 * biquad(src, "bp", 5000, 0.5)
    whistle = svf(noise(n, rng), glide(3400, 3000, n, 1.0), q=15)       # pressure whistle
    roar = biquad(noise(n, rng), "lp", 300)
    valve = modes(n, [900, 1500, 2300], [0.04, 0.03, 0.02], [1.0, 0.6, 0.4]) + burst(n, rng, 0.0002, 0.002, "hp", 3000)
    jet = (unit(hiss) + 0.25 * unit(whistle) + 0.2 * unit(roar)) * amp * (1 + 0.12 * wobble(n, rng, 20))
    return finish(jet + 0.3 * unit(valve), fade_out=0.15)


def heat_alarm(v=0):
    n, m = secs(1.0), secs(0.055)
    tm = times(m)
    x = np.zeros(n)
    for i in range(8):                                                 # eight beeps, climbing
        f0 = 900 * 2 ** (i / 8) * (1 + 0.08 * tm / 0.055)
        beep = np.tanh(2.5 * unit(harmonic(f0, tilt=1.0, fmax=9000)))
        x += place(n, i * 0.11, beep * np.clip(tm / 0.003, 0, 1) * np.clip((0.055 - tm) / 0.005, 0, 1))
    return finish(reverb(x, size=1.0, fb=0.5, mix=0.15), fade_out=0.05)


# ----------------------------------------------------------------------------- player / items / ui

def roll(v=0):
    rng = np.random.default_rng(5700 + v)
    n = secs(0.3)
    p = np.arange(n) / n
    amp = np.sin(np.pi * p ** 0.8) ** 2
    whoosh = unit(svf(noise(n, rng) * amp * (0.6 + 0.4 * rough(n, rng, 40)), 400 + 1400 * np.sin(np.pi * p ** 0.9) ** 2, q=1.2))
    gear = unit(grains(n, rng, 8, 0.05, 0.25, 2500, 6000, decay=1.0, q=5))       # buckles, tools
    scuff = burst(n, rng, 0.002, 0.03, "bp", 2000, 0.8, delay=0.12) + 0.6 * burst(n, rng, 0.002, 0.03, "bp", 1700, 0.8, delay=0.22)
    gravel = unit(grains(n, rng, 25, 0.1, 0.28, 800, 5000, decay=0.1))
    m = n - secs(0.13)
    thump = place(n, 0.13, osc(glide(120, 70, m, 0.03)) * env(m, 0.002, 0.03))
    return finish(0.7 * whoosh + 0.2 * gear + 0.4 * scuff + 0.35 * gravel + 0.3 * thump, fade_out=0.05)


def note_pickup(v=0):
    rng = np.random.default_rng(5800 + v)
    n = secs(0.6)
    rustle = biquad(noise(n, rng) * env(n, 0.02, 0.12) * rough(n, rng, 40) ** 2, "bp", 3500, 0.7)
    crinkle = grains(n, rng, 20, 0.0, 0.3, 3000, 9000, length=(0.0005, 0.002), decay=0.15, q=2)
    tone = (osc(220, n) + 0.6 * osc(261.63, n) + 0.15 * osc(440, n)) * env(n, 0.06, 0.25, delay=0.08)  # A3 + C4
    x = 0.6 * unit(rustle) + 0.3 * unit(crinkle) + 0.5 * unit(tone)
    return finish(reverb(x, size=1.5, fb=0.7, mix=0.3), fade_out=0.1)


def crate_open(v=0):
    rng = np.random.default_rng(5900 + v)
    n, pop_t = secs(0.6), 0.27
    t = times(n)
    clicks, tc = np.zeros(n), 0.02                                     # nails creaking out
    while tc < 0.25:
        clicks[secs(tc)] += rng.uniform(0.4, 1.0)
        tc += 1 / ((30 + 90 * tc / 0.25) * rng.uniform(0.7, 1.3))
    creak = formants(clicks, [(350 * (1 + 0.2 * t), 8, 1.0), (900 * (1 + 0.15 * t), 10, 0.6), (1800, 10, 0.25)])
    pop = modes(n, [300, 720, 1150], [0.04, 0.025, 0.015], [1.0, 0.6, 0.3], delay=pop_t)
    pop = unit(pop) + burst(n, rng, 0.0005, 0.01, "bp", 900, 1.0, delay=pop_t)
    rattle = np.zeros(n)
    for _ in range(3):                                                 # coins and odds inside
        f = rng.uniform(2800, 3800) * np.array([1, 1.47, 2.13])
        rattle += rng.uniform(0.3, 0.7) * modes(n, f, [0.06, 0.04, 0.03], [1.0, 0.6, 0.4], delay=rng.uniform(0.32, 0.5))
        tk = rng.uniform(0.3, 0.5)
        rattle += rng.uniform(0.3, 0.7) * (modes(n, [rng.uniform(500, 900)], [0.02], [1.0], delay=tk)
                                           + 0.5 * burst(n, rng, 0.0005, 0.004, "bp", 1200, 1.0, delay=tk))
    return finish(reverb(0.6 * unit(creak) + 0.8 * unit(pop) + 0.4 * unit(rattle), mix=0.15), fade_out=0.08)


def ui_soft(seed, dur, notes, sweep):
    """Gentle menu blip: two soft sine notes [(t0, Hz)] over a breathy whoosh."""
    rng = np.random.default_rng(seed)
    n = secs(dur)
    x = np.zeros(n)
    for t0, f in notes:
        m = n - secs(t0)
        x += place(n, t0, (osc(f, m) + 0.2 * osc(2 * f, m)) * env(m, 0.005, 0.05))
    whoosh = unit(svf(noise(n, rng) * env(n, 0.03, 0.05), glide(sweep[0], sweep[1], n, dur * 0.6), q=1.0))
    return finish(biquad(unit(x) + 0.25 * whoosh, "lp", 5000), fade_out=0.06)


def ui_open(v=0):
    return ui_soft(6000 + v, 0.3, [(0.0, 523.25), (0.06, 783.99)], (600, 2500))


def ui_close(v=0):
    return ui_soft(6100 + v, 0.25, [(0.0, 783.99), (0.06, 523.25)], (2500, 600))


# ----------------------------------------------------------------------------- music loops

MUSIC_LOOP = 32.0  # seconds


def bell(f, decay=4.0, tierce=1.2):
    """Distant church-ish bell (hum, prime, tierce, quint, nominal, ...) as a 12 s strike.
    tierce=1.2 gives the usual dark minor-third bell, 1.25 a brighter major one."""
    ratios = np.array([0.5, 1.0, tierce, 1.5, 2.0, 2.74])
    decays = decay * np.array([1.2, 1.0, 0.7, 0.5, 0.4, 0.2])
    return modes(secs(12), f * ratios, decays, [0.4, 1.0, 0.5, 0.3, 0.45, 0.2])


def music_title(v=0):
    rng = np.random.default_rng(6200 + v)
    T = MUSIC_LOOP
    t = times(secs(T))
    n = len(t)
    hum = drone(t, rng, [(55.0, 1.0, 1), (55.0625, 0.7, 2), (82.41, 0.45, 3), (110.0, 0.12, 1)], T)
    buf = np.zeros(2 * n)
    for t0, f, a in [(1.0, 440.0, 1.0), (5.0, 523.25, 0.8), (8.0, 659.25, 0.7),     # A4 C5 E5
                     (14.0, 587.33, 0.75), (21.0, 493.88, 0.7), (25.5, 440.0, 0.85)]:  # D5 B4 A4
        buf += a * place(2 * n, t0, bell(f))
    bells = spectral(fold(buf, n), lowband(2500))                     # far away
    bells = periodic(bells, lambda x: reverb(x, size=3.0, fb=0.8, mix=0.8, damp=2500))
    wind = (loop_noise(n, rng, band(600, 0.7)) * (0.5 + 0.5 * lfo(t, 3, 1.0, T)) ** 3
            + loop_noise(n, rng, band(1400, 0.4)) * (0.5 + 0.5 * lfo(t, 5, 2.0, T)) ** 4)
    return finish_loop(hum + 0.45 * unit(bells) + 0.08 * unit(wind), -14.0)


def music_deep(v=0):
    rng = np.random.default_rng(6300 + v)
    T = MUSIC_LOOP
    t = times(secs(T))
    n = len(t)
    sub = drone(t, rng, [(36.71, 1.0, 1), (36.84, 0.8, 2), (55.0, 0.3, 1), (73.42, 0.12, 3)], T)
    swells = np.zeros(n)
    for c, w, chord in [(9.0, 8.0, [146.83, 155.56, 207.65]),         # D3 Eb3 Ab3
                        (24.0, 7.0, [110.0, 116.54, 164.81])]:        # A2 Bb2 E3
        tones = sum(np.sin(TAU * per(f, T) * t + 0.3 * lfo(t, 2, i, T)) + 0.15 * np.sin(TAU * 2 * per(f, T) * t)
                    for i, f in enumerate(chord))
        swells += tones * bump(t, c, w, T) ** 1.5
    breath = loop_noise(n, rng, band(200, 0.6)) * (0.5 + 0.5 * lfo(t, 4, 0.3, T)) ** 4
    return finish_loop(sub + 0.3 * unit(swells) + 0.05 * breath, -16.0)


# ----------------------------------------------------------------------------- gas / water

def explosion(v=0):
    rng = np.random.default_rng(7000 + v)
    n = secs(2.0)
    t = times(n)
    crack = burst(n, rng, 0.0003, 0.008, "hp", 1500) + 0.7 * burst(n, rng, 0.0005, 0.02, "bp", 3000, 0.7)
    boom = osc(glide(70 * (1 + 0.1 * v), 25, n, 0.4)) * env(n, 0.003, 0.35)
    boom += 0.8 * burst(n, rng, 0.005, 0.4, "lp", 150)
    blast = burst(n, rng, 0.002, 0.12, "lp", 1200)
    debris = unit(grains(n, rng, 150, 0.15, 1.8, 400, 5000, decay=0.6, skew=1.3))
    chunks = sum(rng.uniform(0.3, 1.0) * (burst(n, rng, 0.002, 0.04, "lp", 300, delay=tc)
                                          + place(n, tc, osc(glide(110, 50, n - secs(tc), 0.05)) * env(n - secs(tc), 0.002, 0.05)))
                 for tc in np.sort(rng.uniform(0.3, 1.2, 6)))
    tail = unit(biquad(biquad(noise(n, rng), "lp", 80), "lp", 80)) * env(n, 0.05, 1.0) * (0.6 + 0.4 * rough(n, rng, 4))
    x = np.tanh(2.0 * (0.6 * unit(crack) + boom + 0.5 * blast)) + 0.35 * debris + 0.25 * unit(chunks) + 1.0 * tail
    return finish(reverb(x, size=2.0, fb=0.75, mix=0.3, damp=2000), fade_out=0.3)


def gas_hiss(v=0):
    rng = np.random.default_rng(7100 + v)
    T = 2.0
    t = times(secs(T))
    n = len(t)
    hiss = loop_noise(n, rng, band(5000, 1.2)) + 0.4 * loop_noise(n, rng, band(2500, 0.8))
    hiss *= 0.85 + 0.15 * loop_rough(n, rng, 8)
    blub = fold(bubbles(2 * n, rng, 14, 0.0, T, 300, 900), n)          # faint bubbling
    return finish_loop(unit(hiss) + 0.15 * unit(blub), -16.0)


def gas_release(v=0):
    rng = np.random.default_rng(7200 + v)
    n = secs(1.0)
    t = times(n)
    amp = np.clip(t / 0.005, 0, 1) * np.exp(-t / 0.25) * (1 + 0.15 * wobble(n, rng, 25))
    src = noise(n, rng)
    hiss = biquad(src, "hp", 1200) + 0.7 * biquad(src, "bp", 4000, 0.6)
    jet = svf(noise(n, rng), glide(6000, 2500, n, 0.8), q=1.5)          # pressure dropping
    crack = burst(n, rng, 0.0005, 0.01, "bp", 2500, 0.8)
    debris = unit(grains(n, rng, 15, 0.0, 0.2, 800, 5000, decay=0.08))
    whump = burst(n, rng, 0.002, 0.08, "lp", 200)
    x = (unit(hiss) + 0.4 * unit(jet)) * amp + 0.5 * crack + 0.25 * debris + 0.4 * whump
    return finish(x, fade_out=0.15)


def water_leak(v=0):
    rng = np.random.default_rng(7300 + v)
    T = 2.0
    t = times(secs(T))
    n = len(t)
    spray = (loop_noise(n, rng, band(3000, 1.2)) + 0.6 * loop_noise(n, rng, band(800, 0.8))) * (0.6 + 0.4 * loop_rough(n, rng, 40))
    gush = loop_noise(n, rng, band(300, 0.6)) * loop_rough(n, rng, 6)
    buf, m = np.zeros(2 * n), secs(0.012)
    for _ in range(120):                                               # droplets spattering
        f = rng.uniform(1000, 4000)
        buf += rng.uniform(0.2, 1.0) * place(2 * n, rng.uniform(0, T), osc(glide(f, 1.5 * f, m, 0.008)) * env(m, 0.0005, 0.003))
    x = unit(spray) + 0.4 * unit(gush) + 0.2 * unit(fold(buf, n))
    ring = lambda f: 1 + 1.5 * band(420, 0.05)(f) + 1.0 * band(1150, 0.05)(f)  # steel plate resonances
    return finish_loop(spectral(x, ring), -14.0)


def pump(v=0):
    rng = np.random.default_rng(7400 + v)
    T = 1.5
    t = times(secs(T))
    n = len(t)
    buf = np.zeros(2 * n)
    m = secs(0.45)
    tm = times(m)
    for i, t0 in enumerate([0.05, 0.55, 1.05]):                        # three strokes per loop
        a = [1.0, 0.85, 0.92][i]
        thump = osc(glide(90, 50, m, 0.04)) * env(m, 0.002, 0.06)
        clack = modes(m, [700, 1300], [0.03, 0.02], [1.0, 0.5], delay=0.01)
        slosh_amp = np.clip((tm - 0.04) / 0.08, 0, 1) * np.exp(-np.maximum(tm - 0.12, 0) / 0.1)
        slosh = svf(noise(m, rng) * slosh_amp, np.interp(tm, [0, 0.15, 0.4], [300, 900, 400]), q=2.0)
        buf += a * place(2 * n, t0, thump + 0.4 * clack + 0.6 * unit(slosh))
    motor = np.sin(TAU * per(100, T) * t) + 0.3 * np.sin(TAU * per(200, T) * t)
    return finish_loop(fold(buf, n) + 0.06 * motor, -16.0)


def splash(v=0):
    rng = np.random.default_rng(7500 + v)
    n = secs(0.5)
    whump = burst(n, rng, 0.002, 0.06, "lp", 400) + 0.6 * osc(glide(180, 70, n, 0.06)) * env(n, 0.002, 0.05)
    slap = burst(n, rng, 0.001, 0.03, "bp", 1000 * (1 + 0.15 * v), 0.5)
    crash = unit(biquad(noise(n, rng) * env(n, 0.005, 0.12) * rough(n, rng, 50), "bp", 2500, 0.7))
    drops, m = np.zeros(n), secs(0.015)
    for _ in range(40):
        tc = 0.05 + 0.4 * rng.random() ** 1.5
        f = rng.uniform(1000, 5000)
        drops += rng.uniform(0.2, 1.0) * np.exp(-tc / 0.2) * place(n, tc, osc(glide(f, 1.6 * f, m, 0.01)) * env(m, 0.0005, 0.004))
    blub = unit(bubbles(n, rng, 8, 0.05, 0.3, 200, 600))
    x = 0.8 * whump + 0.6 * slap + 0.7 * crash + 0.3 * unit(drops) + 0.3 * blub
    return finish(x, fade_out=0.08)


def air_bubbles(v=0):
    rng = np.random.default_rng(7600 + v)
    n = secs(0.8)
    m = secs(0.2)
    glug = osc(glide(120, 220, n, 0.08)) * env(n, 0.01, 0.05)
    x = np.zeros(n)
    for _ in range(20):                                                # bubbles rising, thinning out
        tc = 0.68 * rng.random() ** 1.2
        f, L = rng.uniform(250, 800), rng.uniform(0.02, 0.04)
        x += rng.uniform(0.4, 1.0) * place(n, tc, osc(glide(f, 1.6 * f, m, L)) * env(m, 0.002, 0.4 * L))
    return finish(biquad(unit(x) + 0.5 * glug, "lp", 2500), fade_out=0.1)    # muffled: underwater


# ----------------------------------------------------------------------------- the eye (final boss)

def eye_open(v=0):
    rng = np.random.default_rng(8000 + v)
    n = secs(2.5)
    t = times(n)
    swell = np.sin(np.pi * np.clip(t / 2.5, 0, 1) ** 1.6) ** 2          # peaks around 1.6 s
    deep = unit(biquad(biquad(noise(n, rng), "lp", 60), "lp", 60))
    pressure = (osc(glide(30, 40, n, 2.0)) + 0.8 * deep) * swell
    clicks, tc = np.zeros(n), 0.2                                      # the lid grinding open
    while tc < 2.2:
        clicks[secs(tc)] += rng.uniform(0.4, 1.0)
        tc += 1 / ((15 + 30 * (tc - 0.2) / 2.0) * rng.uniform(0.6, 1.4))
    slide = 1 + 0.3 * t / 2.5
    creak = formants(clicks, [(180 * slide, 6, 1.0), (420 * slide, 8, 0.6), (900, 8, 0.3)])
    f0 = np.interp(t, [0, 1.2, 2.5], [26, 34, 28]) * (1 + 0.08 * wobble(n, rng, 3))
    groan = np.tanh(2 * worm_voice(f0, rng)) * np.clip(t / 0.5, 0, 1) * np.clip((2.5 - t) / 0.6, 0, 1)
    wet = svf(biquad(noise(n, rng), "lp", 1500) * rough(n, rng, 12) ** 2, 300 + 200 * wobble(n, rng, 3), q=3)
    blub = unit(bubbles(n, rng, 10, 0.3, 2.2, 80, 220))
    grit = unit(grains(n, rng, 80, 0.2, 2.3, 300, 2500, decay=1e9, skew=1.0)) * swell
    x = 0.9 * pressure + 0.5 * unit(creak) + 0.6 * groan + 0.35 * unit(wet) + 0.25 * blub + 0.2 * grit
    return finish(reverb(biquad(x, "lp", 1800), size=2.5, fb=0.75, mix=0.3, damp=1000), fade_out=0.3)


def eye_hurt(v=0):
    rng = np.random.default_rng(8100 + v)
    n = secs(1.0)
    t = times(n)
    f0 = np.interp(t, [0, 0.12, 0.5, 1.0], [90, 165, 120, 70]) * (1 + 0.08 * v)
    f0 = f0 * (1 + 0.03 * np.sin(TAU * 9 * t) + 0.03 * wobble(n, rng, 60))
    src = sum(a * harmonic(f0 * r, tilt=0.7, fmax=6000) for r, a in [(1.0, 1.0), (1.03, 0.7), (0.5, 0.6)])  # inhuman chorus
    voice = formants(src, [(650 * (1 + 0.2 * wobble(n, rng, 4)), 4, 1.0),
                           (1400 * (1 + 0.1 * wobble(n, rng, 4)), 5, 0.7), (2700, 6, 0.4)]) + 0.2 * unit(src)
    shriek = np.tanh(3 * unit(voice)) * np.clip(t / 0.03, 0, 1) * np.exp(-np.maximum(t - 0.35, 0) / 0.25)
    grind_amp = np.clip(t / 0.05, 0, 1) * np.exp(-t / 0.4)
    grind = unit(biquad(noise(n, rng) * rough(n, rng, 20) * grind_amp, "bp", 700, 0.8))
    gravel = unit(grains(n, rng, 50, 0.0, 0.8, 300, 3000, decay=0.4))
    x = shriek + 0.3 * grind + 0.2 * gravel
    return finish(reverb(x, size=2.0, fb=0.7, mix=0.3, damp=3000), fade_out=0.15)


def eye_die(v=0):
    rng = np.random.default_rng(8200 + v)
    n, boom_t = secs(5.0), 3.2
    t = times(n)
    f0 = 80 * (20 / 80) ** np.clip(t / 4.0, 0, 1) * (1 + 0.06 * wobble(n, rng, 3) + 0.02 * wobble(n, rng, 40))
    moan = np.tanh(2 * worm_voice(f0, rng, fmax=3000)) * np.clip(t / 0.3, 0, 1) * np.exp(-np.maximum(t - 2.0, 0) / 0.8)
    cracks = sum(burst(n, rng, 0.0003, 0.01, "hp", 1800, delay=tc) + 0.6 * burst(n, rng, 0.001, 0.05, "bp", 900, 0.8, delay=tc)
                 for tc in [0.8, 1.5, 2.1, 2.6])                       # the floor giving way
    debris = unit(grains(n, rng, 200, 1.0, 4.2, 300, 4000, decay=1.2))
    m = n - secs(boom_t)
    boom = place(n, boom_t, osc(glide(60, 28, m, 0.5)) * env(m, 0.005, 0.6))
    boom += 0.6 * burst(n, rng, 0.003, 0.4, "lp", 200, delay=boom_t)
    hollow = unit(modes(n, [55, 92, 141, 210, 330], [1.5, 1.2, 0.9, 0.6, 0.4], [1.0, 0.7, 0.5, 0.35, 0.2], delay=boom_t))
    ring = modes(n, [880, 1320], [1.5, 1.2], [1.0, 0.6], delay=boom_t) + 0.6 * osc(3150, n) * np.clip((t - 3.4) / 0.5, 0, 1)
    x = 0.8 * moan + 0.5 * unit(cracks) + 0.3 * debris + np.tanh(1.5 * unit(boom)) + 0.5 * hollow + 0.04 * unit(ring)
    return finish(reverb(x, size=3.0, fb=0.8, mix=0.35, damp=1500), fade_out=0.8)


def vein_pulse(v=0):
    rng = np.random.default_rng(8300 + v)
    T = 1.6
    n, m = secs(T), secs(0.5)
    buf = np.zeros(2 * n)
    for t0, a in [(0.1, 1.0), (0.38, 0.7)]:                            # lub ... dub
        thump = osc(glide(70, 38, m, 0.06)) * env(m, 0.003, 0.08)
        body = burst(m, rng, 0.003, 0.05, "lp", 220)
        squish = unit(svf(noise(m, rng) * env(m, 0.005, 0.04), glide(200, 700, m, 0.08), q=3))
        buf += a * place(2 * n, t0, thump + 0.5 * body + 0.25 * squish)
    gurgle = loop_noise(n, rng, band(150, 0.5)) * loop_rough(n, rng, 5)
    return finish_loop(fold(buf, n) + 0.08 * gurgle, -14.0)


def vein_burst(v=0):
    rng = np.random.default_rng(8400 + v)
    n = secs(0.8)
    t = times(n)
    wet = biquad(noise(n, rng), "lp", 2500) * env(n, 0.002, 0.08)
    squelch = unit(svf(wet, np.interp(t, [0, 0.05, 0.25], [300, 1800, 250]), q=3))
    splat = burst(n, rng, 0.002, 0.05, "lp", 600)
    thump = osc(glide(100, 45, n, 0.05)) * env(n, 0.002, 0.06)
    blub = unit(bubbles(n, rng, 8, 0.02, 0.3, 150, 500))
    crack = burst(n, rng, 0.0003, 0.004, "hp", 3000, delay=0.01)          # the crystal core
    shards = unit(pings(n, rng, 25, 0.01, 0.4, 3000, 10000, decay=(0.01, 0.05), fade=0.15, skew=1.5))
    chime = unit(modes(n, [2200, 3333, 5900], [0.25, 0.15, 0.08], [1.0, 0.5, 0.3], delay=0.01))
    x = 0.8 * squelch + 0.5 * splat + 0.6 * thump + 0.3 * blub + 0.5 * crack + 0.4 * shards + 0.2 * chime
    return finish(reverb(x, size=1.3, fb=0.65, mix=0.2), fade_out=0.1)


def knock(v=0):
    rng = np.random.default_rng(8500 + v)
    n = secs(1.5)
    f = 62 * np.array([1, 1.62, 2.31, 2.98, 3.7, 4.53]) * (1 + rng.uniform(-0.01, 0.01, 6))
    decays, amps = [1.2, 0.9, 0.7, 0.5, 0.35, 0.25], np.array([1.0, 0.8, 0.6, 0.45, 0.3, 0.2])
    bong = unit(modes(n, f, decays, amps) + modes(n, f * 1.003 + 0.3, decays, 0.5 * amps))  # vast stone slab
    thump = osc(glide(120, 55, n, 0.06)) * env(n, 0.002, 0.08)
    impact = burst(n, rng, 0.0005, 0.01, "lp", 2000)
    head = unit(modes(n, [900, 1500, 2400], [0.05, 0.03, 0.02], [1.0, 0.6, 0.3]))       # the drill head
    x = np.tanh(1.4 * (bong + 0.8 * thump + 0.5 * impact)) + 0.15 * head
    return finish(reverb(x, size=3.0, fb=0.75, mix=0.4, damp=1500), fade_out=0.3)


# ----------------------------------------------------------------------------- boss / ending music

def add_at(buf, i, x):
    """Mix x into buf starting at sample i (buf must be long enough)."""
    buf[i:i + len(x)] += x


def music_boss(v=0):
    rng = np.random.default_rng(8600 + v)
    beat = 24000                     # samples per beat (110.25 bpm), so every event lands exactly
    eighth = beat // 2
    n = 64 * beat                    # 16 bars of 4/4, ~34.8 s
    E, F, As = 41.20, 43.65, 58.27   # E1, F1, A#1: a semitone grind and a tritone
    roots = [E] * 4 + [F] * 4 + [E] * 4 + [As] * 2 + [F] * 2
    chords = {E: [164.81, 174.61, 246.94], F: [174.61, 185.0, 261.63], As: [116.54, 123.47, 164.81]}
    m = secs(0.3)
    pulse = {f: unit(biquad(harmonic(np.full(m, f), 1.0, 2500) * env(m, 0.003, 0.12), "lp", 700))
             for f in set(roots) | {2 * r for r in roots}}
    ms = secs(0.45)
    tm = times(ms)
    stab = {}
    for root, chord in chords.items():                                 # brassy detuned-saw stabs
        src = sum(harmonic(np.full(ms, f * d), 1.0, 6000) for f in chord for d in (0.996, 1.004))
        stab[root] = np.tanh(1.5 * unit(svf(src, 300 + 2200 * np.exp(-tm / 0.08), q=1.2, mode="lp") * env(ms, 0.012, 0.15)))
    mh = secs(0.4)
    lub = osc(glide(60, 35, mh, 0.06)) * env(mh, 0.003, 0.07)
    heart = lub + 0.7 * np.concatenate([np.zeros(secs(0.22)), lub])[:mh]
    tick = burst(secs(0.03), rng, 0.0003, 0.004, "hp", 6000)
    low, hits, ticks = np.zeros(2 * n), np.zeros(2 * n), np.zeros(2 * n)
    for bar, root in enumerate(roots):
        b0 = bar * 4 * beat
        for k in range(8):                                             # driving eighths, octave on the offbeat
            note = pulse[root] if k % 2 == 0 else 0.6 * pulse[2 * root]
            add_at(low, b0 + k * eighth, (1.0 if k in (0, 4) else 0.6) * note)
        steps = 8 if bar < 8 else 16                                   # hats double up halfway
        for k in range(steps):
            add_at(ticks, b0 + k * (4 * beat // steps), (0.5 if k % 2 else 0.3) * rng.uniform(0.8, 1.0) * tick)
        if bar % 2 == 0 or bar >= 12:
            add_at(hits, b0, stab[root])
            add_at(hits, b0 + int(2.5 * beat), 0.7 * stab[root])
    for b in range(0, 64, 2):
        add_at(low, b * beat, 0.8 * heart)
    stabs = periodic(fold(hits, n), lambda x: reverb(x, size=1.5, fb=0.7, mix=0.5, damp=3000))
    start = 48 * beat                                                  # last 4 bars: riser into the loop point
    L = n - start
    pr = np.arange(L) / L
    cut = np.clip((L - 1 - np.arange(L)) / secs(0.02), 0, 1)
    riser = unit(svf(noise(L, rng) * pr ** 2, 400 * 10 ** pr, q=2.0))
    tr = times(L)
    cluster = (osc(329.63 * (1 + 0.06 * pr)) + osc(349.23 * (1 + 0.06 * pr))) * (0.6 + 0.4 * np.sin(TAU * 8 * tr)) * pr ** 1.5
    tension = np.zeros(n)
    add_at(tension, start, (0.7 * riser + 0.3 * cluster) * cut)
    x = fold(low, n) + 0.5 * stabs + 0.15 * fold(ticks, n) + tension
    return finish_loop(x, -12.0)


def music_ending(v=0):
    rng = np.random.default_rng(8700 + v)
    n = secs(40.0)
    t = times(n)
    swell = np.clip(t / 6, 0, 1) * (0.6 + 0.4 * np.clip((t - 14) / 10, 0, 1))
    minor = np.clip((16 - t) / 4, 0, 1)                               # C3 fades out...
    major = np.clip((t - 16) / 8, 0, 1)                                # ...C#3 fades in: the turn to hope
    drone = (osc(55.0, n) * (0.8 + 0.2 * np.sin(TAU * t / 9)) + 0.5 * osc(82.41, n) + 0.25 * osc(110.0, n)
             + 0.2 * minor * osc(130.81, n) + 0.25 * major * osc(138.59, n)) * swell
    pad = np.zeros(n)
    for start, end, chord in [(12.0, 22.0, [146.83, 185.0, 220.0]),             # D major
                              (19.0, 40.0, [110.0, 138.59, 164.81, 220.0])]:      # A major
        m = secs(end - start)
        tm = times(m)
        src = sum(harmonic(np.full(m, f * d), 1.2, 1500) for f in chord for d in (0.997, 1.003))
        pad += place(n, start, biquad(src, "lp", 900) * np.clip(tm / 3, 0, 1) * np.clip((end - start - tm) / 4, 0, 1))
    bells = np.zeros(n)
    for t0, f, a, tierce in [(2.0, 440.0, 0.8, 1.2), (6.5, 523.25, 0.7, 1.2), (10.5, 659.25, 0.6, 1.2),
                             (14.5, 587.33, 0.6, 1.2),                              # the title motif, minor
                             (19.0, 440.0, 0.9, 1.25), (22.0, 554.37, 0.8, 1.25), (25.0, 659.25, 0.8, 1.25),
                             (28.5, 587.33, 0.7, 1.25), (31.5, 493.88, 0.7, 1.25), (34.5, 440.0, 0.9, 1.25),
                             (37.0, 880.0, 0.4, 1.25)]:                             # ...answered in A major
        bells += a * place(n, t0, bell(f, tierce=tierce))
    bells = reverb(biquad(bells, "lp", 2500), size=3.0, fb=0.8, mix=0.8, damp=2500)
    x = unit(drone) + 0.35 * unit(pad) + 0.45 * unit(bells)
    return finish(x, peak_db=-12.0, fade_in=1.0, fade_out=6.0)


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
    **variants("bat_screech", bat_screech, 3),
    "bat_flap": bat_flap,
    **variants("crystal_hit", crystal_hit, 3),
    "crystal_break": crystal_break,
    "lava_bubble": lava_bubble,
    "sizzle": sizzle,
    "steam_vent": steam_vent,
    "heat_alarm": heat_alarm,
    "roll": roll,
    "note_pickup": note_pickup,
    "crate_open": crate_open,
    "ui_open": ui_open,
    "ui_close": ui_close,
    "music_title": music_title,
    "music_deep": music_deep,
    **variants("explosion", explosion, 2),
    "gas_hiss": gas_hiss,
    "gas_release": gas_release,
    "water_leak": water_leak,
    "pump": pump,
    **variants("splash", splash, 2),
    "bubbles": air_bubbles,
    "eye_open": eye_open,
    **variants("eye_hurt", eye_hurt, 2),
    "eye_die": eye_die,
    "vein_pulse": vein_pulse,
    "vein_burst": vein_burst,
    "knock": knock,
    "music_boss": music_boss,
    "music_ending": music_ending,
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
