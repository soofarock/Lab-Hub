# Granular noise under Roblox rules. Generic grain files: K windowed noise puffs (from the shared octave noise loops), each
# after LEAD seconds of silence (file time). A grain starting `d` seconds into block b is a player that, on the block
# before, gets TimePosition = start_k - d*speed, PlaybackSpeed = speed, Volume = v, Play (all land on boundary b).
import numpy as np, render as RN, ridges as RG, v4
from scipy.signal import butter, sosfiltfilt
R, BLK = 48000, 1024
LEAD, K = 0.095, 24
G_FILE = {'noise_4_1000': 0.020, 'noise_6_4000': 0.010}  # grain length in file seconds (real = this / speed)
BANDS = [177, 354, 707, 1414, 2828, 5657]                     # octave centres
def src_of(c):
    return ('noise_4_1000', c / 1000) if c <= 2900 else ('noise_6_4000', c / 4000)
FILES = {}
CRK_RATE = {}  # (src) -> click rate of the crackle the high-band grains are cut from (None: smooth noise)
CRK_FROM = 1400  # bands from this centre up use the crackle grains
def make_files():
    import crackle as CK
    for src, G in G_FILE.items():
      for kind in ('smooth', 'crackle'):
        x, L, sr = RN.asset(src); x = x[1:L + 1]
        if kind == 'crackle':
            if not CRK_RATE.get(src): continue
            x = CK.make(src, CRK_RATE[src], seconds=L / R)
        rms = np.sqrt(np.mean(x ** 2))
        g = int(G * R); w = np.sin(np.pi * (np.arange(g) + 0.5) / g)  # sine window: power-complementary at 50% overlap
        rng = np.random.default_rng(5)
        parts, starts, pos = [], [], 0
        for k in range(K):
            parts.append(np.zeros(int(LEAD * R))); pos += int(LEAD * R)
            o = rng.integers(0, L - g); seg = x[o:o + g] * w
            starts.append(pos / R); parts.append(seg); pos += g
        parts.append(np.zeros(int(0.005 * R)))
        y = np.concatenate(parts)
        nm = 'grain_' + src.split('_')[-1] + ('' if kind == 'smooth' else '_crk')
        RN._assets[nm] = (np.concatenate([y[-1:], y, y[:3]]), len(y), R)
        FILES[(src, kind)] = dict(name=nm, starts=starts, G=G, rms=rms, src=x)
CLEAN = False
HALF = 0.5  # band width in octaves (1 = octave bands)
OVERLAP = 2  # puffs sounding at once (2: hop = G/2; 4: hop = G/4)
LOWPASS = None
MIN_BAND = 177
G_REAL = None  # seconds: grain length heard in every band (None: one puff length per file, scaled by speed)
G_REAL_LOW = 0.014  # bands under 500 Hz
G_REAL_SUB = 0.025  # bands under 200 Hz (longer grains spread less energy below the band)
def file_for(c):
    src, sp = src_of(c)
    kind = 'crackle' if (c >= CRK_FROM and (src, 'crackle') in FILES) else 'smooth'
    if G_REAL:
        g = (G_REAL if c >= 500 else (G_REAL_LOW if c >= 200 else G_REAL_SUB)) * sp
        key = (src, kind, round(g, 5))
        if key not in FILES:
            FILES[key] = _build(src, kind, g)
        return FILES[key], sp
    return FILES[(src, kind)], sp
def _build(src, kind, G):
    import crackle as CK
    x, L, sr = RN.asset(src); x = x[1:L + 1]
    if kind == 'crackle':
        x = CK.make(src, CRK_RATE[src], seconds=L / R)
    if CLEAN:
        # the grain files are new uploads: cut them from noise limited tightly to the file's own octave (the shared noise
        # loops have skirts that land far above the band when played fast: hiss)
        c0 = 1000.0 if src == 'noise_4_1000' else 4000.0
        X = np.fft.rfft(np.tile(x, 1)); f = np.fft.rfftfreq(L, 1 / R)
        lo, hi = c0 / 2 ** (HALF / 2), c0 * 2 ** (HALF / 2)
        Hf = 1 / np.sqrt(1 + (f / hi) ** 16) / np.sqrt(1 + (lo / np.maximum(f, 1)) ** 16)
        x = np.fft.irfft(X * Hf, L)
    rms = np.sqrt(np.mean(x ** 2))
    g = max(16, int(G * R)); w = np.sin(np.pi * (np.arange(g) + 0.5) / g)
    rng = np.random.default_rng(5)
    parts, starts, pos = [], [], 0
    for k in range(K):
        parts.append(np.zeros(int(LEAD * R))); pos += int(LEAD * R)
        o = rng.integers(0, L - g); parts.append(x[o:o + g] * w); starts.append(pos / R); pos += g
    parts.append(np.zeros(int(0.005 * R)))
    y = np.concatenate(parts); nm = 'grain_%s_%s_%d' % (src.split('_')[-1], kind, g)
    RN._assets[nm] = (np.concatenate([y[-1:], y, y[:3]]), len(y), R)
    return dict(name=nm, starts=starts, G=g / R, rms=rms, src=x)
make_files()
_unit = {}
def unit_power(c, nyq):
    """steady power the band's noise file delivers through the same band filter at volume 1 (grains overlap to a steady
    stream with the sine window at 50 %)"""
    key = (c, nyq, file_for(c)[0]['name'])
    if key not in _unit:
        F, sp = file_for(c); x = F['src']; L = len(x)
        y = np.interp(np.arange(0, L - 1, sp), np.arange(L), x)
        sos = butter(4, [c / 2 ** (HALF / 2), min(c * 2 ** (HALF / 2), nyq * 0.99)], 'bandpass', fs=R, output='sos')
        _unit[key] = float(np.mean(sosfiltfilt(sos, np.tile(y, 2))[len(y) // 2:len(y) // 2 + len(y)] ** 2))
    return _unit[key]
def encode(x, tone, nyq=8000):
    """grain levels per band from the analysis: band power of the sound minus the tone layer, per grain window"""
    out = []
    for c in BANDS:
        if c * 2 ** (HALF / 2) > nyq * 1.06: continue
        F, sp = file_for(c)
        G = F['G'] / sp; hop = G / OVERLAP
        sos = butter(4, [c / 2 ** (HALF / 2), min(c * 2 ** (HALF / 2), nyq * 0.99)], 'bandpass', fs=R, output='sos')
        xb, tb = sosfiltfilt(sos, x) ** 2, sosfiltfilt(sos, tone) ** 2
        g = int(G * R); w = np.sin(np.pi * (np.arange(g) + 0.5) / g) ** 2; w /= w.sum()
        t = 0.0
        while t < len(x) / R:
            a = int(t * R); seg = slice(a, a + g)
            px, pt = np.dot(xb[seg], w[:len(xb[seg])]), np.dot(tb[seg], w[:len(tb[seg])])
            p = max(px - pt, 0.05 * px)
            if p > 1e-12:
                out.append(dict(band=c, t=t, vol=float(np.sqrt(p / unit_power(c, nyq) * 2 / OVERLAP))))
            t += hop
    return out
def schedule(grains, n_blocks):
    """grain events -> per-player AudioPlayer writes (block index of the write, code, value), as the engine applies them"""
    ev, pools, rng = {}, {}, np.random.default_rng(9)
    pid = 1000
    stats = dict(starts=0, players=0)
    for gr in sorted(grains, key=lambda g: g['t']):
        F, sp = file_for(gr['band'])
        b = int(gr['t'] * R // BLK); d = gr['t'] - b * BLK / R
        if b < 1: b, d = 1, 0.0
        busy_until = b * BLK / R + d + F['G'] / sp + 0.002
        pool = pools.setdefault(gr['band'], [])
        p = None
        for q in pool:
            if q['free'] <= b * BLK / R: p = q; break
        if p is None:
            pid += 1; p = dict(pid=pid, free=0); pool.append(p); ev[pid] = [(0, 'A', F['name'])]; stats['players'] += 1
        k = rng.integers(0, K)
        ev[p['pid']] += [(b - 1, 'T', F['starts'][k] - d * sp), (b - 1, 'S', sp), (b - 1, 'V', gr['vol']), (b - 1, 'P', 1)]
        # silent from the first boundary after the grain (the file goes on to its next puff after LEAD)
        b_end = int(np.ceil(busy_until * R / BLK))
        ev[p['pid']].append((b_end - 1, 'V', 0.0))
        p['free'] = b_end * BLK / R; stats['starts'] += 1
    return ev, stats
def render(grains, n):
    nb = n // BLK + 3
    grains = [g for g in grains if g['band'] >= MIN_BAND]
    ev, st = schedule(grains, nb)
    # Play() on an already playing player is a no-op in the engine; the renderer restarts on T anyway (T lands on the boundary)
    y = RN.render(ev, nb)[:n]
    if LOWPASS:
        y = sosfiltfilt(butter(8, LOWPASS, 'lowpass', fs=R, output='sos'), y)  # one AudioFilter on the clip's output
    return y, st
