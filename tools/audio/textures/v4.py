# Realistic offline model of the "texture" codec (no peeking at the original at synthesis time; Roblox rules: noise levels
# change once per 1024-sample block, short events are generic files started at an exact time, volume fixed per event).
#   layers: blips (short gliding tones: generic decaying-chirp files at a speed), hits (generic noise bursts), noise bands
#   (the shared octave noise files at speeds, smooth or crackle per band), all from the analysis below.
import numpy as np, render as RN, ridges as RG, crackle as CK, hits as H
from scipy.optimize import nnls
from scipy.signal import butter, sosfiltfilt
from scipy.stats import kurtosis
R, BLK = 48000, 1024
HIT_RISE, QUIET, QUIET_GAIN = 8, None, 1.0
SMOOTH, SMOOTH_GAIN = None, 1.0
CRACKLE_ALL = False
HIT_GAP = 0.0
# ---------------- generic blip files: decaying tone at 1 kHz, glide ratio r over `cyc` cycles ----------------
BLIP_R = (0.85, 1.0, 1.25, 1.6)
BLIP_C = (12, 25, 50, 100)
def blip(r, cyc, f0=1000.0, attack=0.12):
    T = cyc / (f0 * (1 + r) / 2)  # length so that ~cyc cycles fit (mean frequency)
    n = int(T * R); t = np.arange(n) / R
    f = f0 * r ** (t / T)
    ph = 2 * np.pi * np.cumsum(f) / R
    env = np.minimum(1, t / (attack * T)) * np.exp(-3.0 * t / T)  # ~ -26 dB at the end
    tail = np.exp(-np.arange(int(0.2 * n)) / (0.05 * n + 1))
    y = np.concatenate([env * np.sin(ph), (env[-1] * tail) * np.sin(ph[-1] + 2 * np.pi * f[-1] * np.arange(1, len(tail) + 1) / R)])
    return y / np.abs(y).max()
BLIPS = {(r, c): blip(r, c) for r in BLIP_R for c in BLIP_C}
# ---------------- noise bands: the shared octave noise files at speeds, half-octave centres ----------------
CENTERS = [125 * 2 ** (i / 2) for i in range(13)]  # 125 .. 8000 Hz
def band_src(c):
    return ('noise_4_1000', c / 1000) if c <= 4000 else ('noise_6_4000', c / 4000)
EDGES = [CENTERS[0] / 2 ** 0.25] + [c * 2 ** 0.25 for c in CENTERS]
def asset_psd(name, speed, crackle=None):
    """power of a noise file played at `speed` in each half-octave bin of EDGES (per unit volume)"""
    x, L, sr = RN.asset(name); x = x[1:L + 1]
    P = np.abs(np.fft.rfft(x)) ** 2 / L ** 2 * 2; f = np.fft.rfftfreq(L, 1 / sr) * speed
    return np.array([P[(f >= a) & (f < b)].sum() for a, b in zip(EDGES[:-1], EDGES[1:])])
_crk = {}
def crackle_file(src, level):
    key = (src, level)
    if key not in _crk:
        rate = {('noise_4_1000', 1): 2000, ('noise_4_1000', 2): 500, ('noise_4_1000', 3): 150,
                ('noise_6_4000', 1): 10000, ('noise_6_4000', 2): 2500, ('noise_6_4000', 3): 700}[key]
        y = CK.make(src, rate); nm = 'crk_%s_%d' % (src, level)
        RN._assets[nm] = (np.concatenate([y[-1:], y, y[:3]]), len(y), R); _crk[key] = nm
    return _crk[key]
CRK_K = {1: (4.6, 5.6), 2: (7.3, 11.0), 3: (9.8, 22.3)}  # crackle (kurtosis) of the 1k / 4k files per level
# ---------------- analysis ----------------
def bins_power(x, a, b):
    """mean power per half-octave bin over samples [a, b)"""
    seg = x[max(a, 0):b]
    if len(seg) < 64: return np.zeros(len(CENTERS))
    w = np.hanning(len(seg)); P = np.abs(np.fft.rfft(seg * w)) ** 2 / (np.sum(w ** 2) * len(seg)) * 2 * len(seg) / len(seg)
    P = np.abs(np.fft.rfft(seg * w)) ** 2 * 2 / (np.sum(w ** 2) * len(seg))
    f = np.fft.rfftfreq(len(seg), 1 / R)
    return np.array([P[(f >= lo) & (f < hi)].sum() for lo, hi in zip(EDGES[:-1], EDGES[1:])])
def encode(x, nyq=8000):
    ev = dict(blips=[], hits=[], noise=None, crackle={})
    # 1. tones (short window ridge tracker) -> blips
    tr, hop, win = RG.track(x)
    tone = RG.synth(tr, hop, win, len(x))
    for t in tr:
        f = np.array(t['f']); a = np.array(t['a']); T = len(f) * hop / R
        r = f[-1] / f[0]; cyc = f.mean() * T
        rb = min(BLIP_R, key=lambda q: abs(np.log(q / r))); cb = min(BLIP_C, key=lambda q: abs(np.log(q / cyc)))
        ev['blips'].append(dict(t=t['start'] * hop + win // 2 - hop // 2, key=(rb, cb), speed=f[0] / 1000.0, amp=float(a.max())))
    resid_ref = x  # (waveform subtraction of unaligned tones adds energy: energies are subtracted instead)
    # 2. hits: onsets of the 2.5 ms envelope; bursts fitted to what the hit adds over the level just before it, minus tones
    hb = sosfiltfilt(butter(4, [1500, min(7800, nyq * 0.97)], 'bandpass', fs=R, output='sos'), x)
    last = -10 ** 9
    for t in H.detect(hb, rise=HIT_RISE):
        if t - last < HIT_GAP * R: continue
        last = t
        n = int(0.008 * R)
        need = H.band_e(x[t:t + n]) - H.band_e(x[max(t - n, 0):t]) - np.maximum(H.band_e(tone[t:t + n]) - H.band_e(tone[max(t - n, 0):t]), 0)
        need = np.maximum(need, 0)
        if need.sum() <= 0: continue
        SH = [b for b in H.BURSTS if b.endswith('_t6')]
        A = np.array([H.band_e(BURST[b][:n]) for b in SH]).T
        g, _ = nnls(A, need)
        for b, gi in zip(SH, g):
            if gi > 1e-12: ev['hits'].append(dict(t=t, name=b, amp=float(np.sqrt(gi))))
    hits_sig = render_hits(ev['hits'], len(x))
    # 3. noise: per block, per half-octave bin, the power not explained by tones and hits
    nb = len(x) // BLK + 2
    lev = np.zeros((nb, len(CENTERS)))
    for b in range(nb):
        a0, a1 = b * BLK - BLK // 2, b * BLK + BLK + BLK // 2  # a little wider than the block (smoother levels)
        if QUIET:
            # band power of 2.7 ms sub-frames; the block's noise = a low percentile (clicks belong to the hit layer)
            sub = []
            for s0 in range(a0, a1 - 256, 128):
                sub.append(bins_power(x, s0, s0 + 256) - bins_power(tone, s0, s0 + 256))
            sub = np.maximum(np.array(sub), 0)
            p = np.percentile(sub, QUIET, axis=0) * QUIET_GAIN if len(sub) else np.zeros(len(CENTERS))
        else:
            p = bins_power(x, a0, a1) - bins_power(tone, a0, a1) - bins_power(hits_sig, a0, a1)
        lev[b] = np.maximum(p, 0)
    lev[:, [i for i, c in enumerate(CENTERS) if c * 2 ** 0.25 > nyq]] = 0
    if SMOOTH:
        # trade level accuracy for no block-rate pulsing: the level (dB) moves at most SMOOTH dB per block, smoothed both ways
        L = 10 * np.log10(lev + 1e-14)
        for _ in range(2):
            for b in range(1, len(L)):
                L[b] = np.clip(L[b], L[b - 1] - SMOOTH, L[b - 1] + SMOOTH)
            for b in range(len(L) - 2, -1, -1):
                L[b] = np.clip(L[b], L[b + 1] - SMOOTH, L[b + 1] + SMOOTH)
        lev = np.where(lev > 0, 10 ** (L / 10), 0) * SMOOTH_GAIN
    ev['noise'] = lev
    # 4. crackle per band from the residual (hits excluded: their regions are skipped)
    mask = np.ones(len(x), bool)
    for h in ev['hits']: mask[h['t']:h['t'] + int(0.012 * R)] = False
    for i, c in enumerate(CENTERS):
        if c < 1400 or c * 2 ** 0.25 > nyq: continue
        sos = butter(4, [c / 2 ** 0.25, min(c * 2 ** 0.25, 23000)], 'bandpass', fs=R, output='sos')
        y = sosfiltfilt(sos, resid_ref)
        w = int(0.02 * R); ks = [kurtosis(y[j:j + w][mask[j:j + w]], fisher=False) for j in range(0, len(y) - w, w) if mask[j:j + w].sum() > w // 2 and np.std(y[j:j + w]) > 1e-6]
        k = np.median(ks) if ks else 3
        src = band_src(c)[0]; col = 0 if src == 'noise_4_1000' else 1
        if CRACKLE_ALL:
            # the dense clicks the hit layer leaves out are part of this band's texture: measure with them in
            ks = [kurtosis(y[j:j + w], fisher=False) for j in range(0, len(y) - w, w) if np.std(y[j:j + w]) > 1e-6]
            k = np.median(ks) if ks else 3
        lvl = 0 if k < 4.0 else min((1, 2, 3), key=lambda L: abs(np.log(CRK_K[L][col] / k)))
        ev['crackle'][i] = lvl
    return ev
BURST = {}
def _bursts():
    for b in H.BURSTS:
        x, L, sr = RN.asset(b); BURST[b] = x[1:L + 1]
_bursts()
def render_hits(hits, n):
    y = np.zeros(n)
    for h in hits:
        s = BURST[h['name']] * h['amp']; m = min(len(s), n - h['t'])
        if m > 0: y[h['t']:h['t'] + m] += s[:m]
    return y
# ---------------- playback (Roblox rules) ----------------
def render(ev, n, nyq=8000):
    y = np.zeros(n)
    # blips: one write each (exact start through a lead-in), fixed volume
    for bl in ev['blips']:
        s = BLIPS[bl['key']]
        # play at speed: resample by linear interpolation
        idx = np.arange(0, len(s) - 1, bl['speed']); seg = np.interp(idx, np.arange(len(s)), s) * bl['amp']
        t = bl['t']; m = min(len(seg), n - t)
        if m > 0: y[t:t + m] += seg[:m]
    y += render_hits(ev['hits'], n)
    # noise bands: per block volumes from a non-negative fit over all bins (each file spreads over ~2 bins), one player per band
    lev = ev['noise']; nb = lev.shape[0]
    names, A = [], []
    for i, c in enumerate(CENTERS):
        src, sp = band_src(c)
        name = crackle_file(src, ev['crackle'][i]) if ev['crackle'].get(i, 0) else src
        col = asset_psd(src, sp)
        if name != src:
            xs, L, sr = RN.asset(name); xo, Lo, _ = RN.asset(src)
            col = col * np.mean(xs[1:L + 1] ** 2) / np.mean(xo[1:Lo + 1] ** 2)
        names.append((name, sp)); A.append(col)
    A = np.array(A).T
    V = np.zeros((nb, len(CENTERS)))
    for b in range(nb):
        if lev[b].sum() > 0:
            V[b], _ = nnls(A, lev[b])
    for i, c in enumerate(CENTERS):
        if not V[:, i].any(): continue
        name, sp = names[i]
        vol = np.sqrt(V[:, i])
        evp = [(0, 'A', name), (0, 'S', sp), (0, 'P', 1)] + [(b - 1, 'V', float(v)) for b, v in enumerate(vol)]
        y += RN.render({1: evp}, nb)[:n] if nb * BLK >= n else np.pad(RN.render({1: evp}, nb), (0, n - nb * BLK))[:n]
    if nyq < R / 2:
        y = sosfiltfilt(butter(8, nyq * 0.98, 'lowpass', fs=R, output='sos'), y)
    return y
