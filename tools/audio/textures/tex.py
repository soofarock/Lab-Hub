# Texture codec, reference implementation (what the Luau importer does, step for step; numpy only at run time).
#   encode(x48) -> dict(bubbles, clicks, grains, fc, n)      render(enc) -> waveform (offline model of the game playback)
# Layers: bubbles (generic gliding-tone shapes at a speed), clicks (generic decaying octave-noise bursts), grains (sine-
# windowed noise puffs per half-octave band at a fixed hop), all placed at exact times; output low-passed at fc.
import numpy as np
R = 48000

# ---------------------------------------------------------------- primitives (each has a Luau twin)
def hann_sym(n):            # numpy.hanning
    return 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / (n - 1))
def hann_per(n):            # periodic Hann (STFT with exact overlap-add)
    return 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)
def median_axis(M, size, axis):
    """median filter along one axis, edges repeat the end value ('nearest')"""
    h = size // 2
    pad = [(0, 0), (0, 0)]; pad[axis] = (h, h)
    P = np.pad(M, pad, mode='edge')
    idx = np.arange(size)
    if axis == 0:
        W = np.stack([P[i:i + M.shape[0]] for i in idx], 0)
    else:
        W = np.stack([P[:, i:i + M.shape[1]] for i in idx], 0)
    return np.median(W, 0)
def median1(v, size):
    return median_axis(v[None, :], size, 1)[0]
def sosfilt(sos, x):
    y = x.copy()
    for b0, b1, b2, a0, a1, a2 in sos:
        out = np.empty_like(y); z1 = z2 = 0.0
        for i in range(len(y)):          # (vectorised version below is used; this is the definition)
            v = y[i]; o = b0 * v + z1; z1 = b1 * v - a1 * o + z2; z2 = b2 * v - a2 * o; out[i] = o
        y = out
    return y
def _sosfilt_fast(sos, x):
    from scipy.signal import sosfilt as sf
    return sf(sos, x)
PADLEN = 1024
def filtfilt(sos, x):
    """zero-phase: odd extension of PADLEN at both ends, forward then backward, zero initial state"""
    p = min(PADLEN, len(x) - 1)
    ext = np.concatenate([2 * x[0] - x[p:0:-1], x, 2 * x[-1] - x[-2:-p - 2:-1]])
    y = _sosfilt_fast(sos, ext); y = _sosfilt_fast(sos, y[::-1])[::-1]
    return y[p:p + len(x)]
_SOS = {}
def bp(lo, hi):
    key = (round(lo, 3), round(hi, 3))
    if key not in _SOS:
        from scipy.signal import butter
        _SOS[key] = butter(4, [lo, hi], 'bandpass', fs=R, output='sos')
    return _SOS[key]
def lp(fc, order=4):
    key = ('lp', round(fc, 3), order)
    if key not in _SOS:
        from scipy.signal import butter
        _SOS[key] = butter(order, fc, 'lowpass', fs=R, output='sos')
    return _SOS[key]
def nextpow2(n):
    return 1 << int(np.ceil(np.log2(max(n, 1))))
def analytic(x):
    """analytic signal through an FFT of the next power of two (zero padded)"""
    n = len(x); N = nextpow2(n)
    X = np.fft.fft(x, N); h = np.zeros(N); h[0] = 1; h[N // 2] = 1; h[1:N // 2] = 2
    return np.fft.ifft(X * h)[:n]
def resample48(x, sr, taps=16):
    """windowed sinc (Hann over +-taps input samples), cutoff 0.95 x the lower Nyquist"""
    if sr == R: return x.astype(float)
    n_out = int(np.floor(len(x) * R / sr))
    fc = 0.95 * min(sr, R) / 2 / sr          # cutoff in cycles per input sample
    t = np.arange(n_out) * sr / R
    k0 = np.floor(t).astype(int)
    y = np.zeros(n_out)
    scale = max(1.0, sr / R)
    for k in range(-taps + 1, taps + 1):
        kk = k0 + k; d = t - kk
        w = 0.5 + 0.5 * np.cos(np.pi * d / (taps * scale))
        s = 2 * fc * np.sinc(2 * fc * d) * w * (np.abs(d) < taps * scale)
        ok = (kk >= 0) & (kk < len(x))
        y[ok] += x[kk[ok]] * s[ok]
    return y

class Prng:
    """xorshift32 + Box-Muller: the same numbers in Python and Luau"""
    def __init__(self, seed):
        self.s = (int(seed) * 2654435761 + 12345) & 0xFFFFFFFF or 1
    def u32(self):
        s = self.s; s ^= (s << 13) & 0xFFFFFFFF; s ^= s >> 17; s ^= (s << 5) & 0xFFFFFFFF; self.s = s; return s
    def uniform(self):           # (0, 1)
        return ((self.u32() >> 8) + 0.5) / 16777216.0
    def normals(self, n):
        out = np.empty(n); i = 0
        while i < n:
            u1, u2 = self.uniform(), self.uniform(); r = np.sqrt(-2 * np.log(u1))
            out[i] = r * np.cos(2 * np.pi * u2)
            if i + 1 < n: out[i + 1] = r * np.sin(2 * np.pi * u2)
            i += 2
        return out
    def uniforms(self, n):
        return np.array([self.uniform() for _ in range(n)])

# ---------------------------------------------------------------- 1. split: tones / noise (median filtering of the STFT)
SP_N, SP_H, SP_T, SP_F = 1024, 64, 11, 11
def stft(x, N, H, win):
    pad = N // 2; xp = np.concatenate([np.zeros(pad), x, np.zeros(pad + N)])
    nf = (len(x) + H - 1) // H + 1
    fr = np.stack([xp[j * H:j * H + N] * win for j in range(nf)])
    return np.fft.rfft(fr, axis=1)
def istft(Z, n, N, H, win):
    pad = N // 2; out = np.zeros(n + 2 * N + pad); wsum = np.zeros_like(out)
    fr = np.fft.irfft(Z, N, axis=1)
    for j in range(len(Z)):
        out[j * H:j * H + N] += fr[j] * win; wsum[j * H:j * H + N] += win * win
    return (out / np.maximum(wsum, 1e-9))[pad:pad + n]
def split(x):
    w = hann_per(SP_N); Z = stft(x, SP_N, SP_H, w); M = np.abs(Z)
    Hm = median_axis(M, SP_T, 0); Pm = median_axis(M, SP_F, 1)
    mh = Hm ** 2 / (Hm ** 2 + Pm ** 2 + 1e-20)
    return istft(Z * mh, len(x), SP_N, SP_H, w), istft(Z * (1 - mh), len(x), SP_N, SP_H, w)

# ---------------------------------------------------------------- 2. tone seeds (ridge tracker)
def track(x, win, hop=128, fmin=300, fmax=7000, prom_db=10, max_jump=0.12, min_frames=6, nfft=4096):
    w = hann_sym(win); lo, hi = int(np.ceil(fmin * nfft / R)), int(np.ceil(fmax * nfft / R))
    frames = []
    for s in range(0, len(x) - win, hop):
        X = np.abs(np.fft.rfft(x[s:s + win] * w, nfft)); P = 20 * np.log10(X + 1e-12)
        pk = []
        for i in range(lo + 1, hi - 1):
            if P[i] > P[i - 1] and P[i] >= P[i + 1]:
                nb = np.concatenate([P[max(lo, i - 40):i - 8], P[i + 9:min(hi, i + 41)]])
                if len(nb) and P[i] - np.median(nb) > prom_db:
                    a, b, c = P[i - 1], P[i], P[i + 1]; d = 0.5 * (a - c) / (a - 2 * b + c)
                    pk.append(((i + d) * R / nfft, 10 ** ((b - 0.25 * (a - c) * d) / 20) * 2 / w.sum()))
        frames.append(pk)
    tracks, live = [], []
    for j, pk in enumerate(frames):
        used = set(); nxt = []
        for tr in live:
            fl = tr['f'][-1]; best, bd = None, max_jump
            for q, (fq, aq) in enumerate(pk):
                if q in used: continue
                dv = abs(fq / fl - 1)
                if dv < bd: best, bd = q, dv
            if best is not None:
                used.add(best); tr['f'].append(pk[best][0]); tr['a'].append(pk[best][1]); nxt.append(tr)
            else:
                tracks.append(tr)
        for q, (fq, aq) in enumerate(pk):
            if q not in used: nxt.append(dict(start=j, f=[fq], a=[aq]))
        live = nxt
    tracks += live
    return [t for t in tracks if len(t['f']) >= min_frames]
def seeds(x):
    out = []
    for win in (1024, 512):
        for t in track(x, win):
            f = np.array(t['f']); a = np.array(t['a'])
            t0 = (t['start'] * 128 + win // 2 - 64) / R; d = len(f) * 128 / R
            fm = np.exp(np.sum(a ** 2 * np.log(f)) / np.sum(a ** 2))
            if any(abs(np.log(s['fm'] / fm)) < 0.15 and s['t0'] < t0 + d and t0 < s['t0'] + s['d'] for s in out): continue
            out.append(dict(t0=t0, d=d, fm=fm))
    return out

# ---------------------------------------------------------------- 3. bubble shapes (generic files) and the fit
def shape(r, c, p, dec, f0=1000.0, attack=0.12):
    tau = np.linspace(0, 1, 2001); T = c / (f0 * np.mean(r ** (tau ** p)))
    n = int(T * R); t = np.arange(n) / R
    f = f0 * r ** ((t / T) ** p); ph = 2 * np.pi * np.cumsum(f) / R
    env = np.minimum(1, t / (attack * T)) * 10 ** (-dec / 20 * t / T)
    m = int(0.2 * n); tail = np.exp(-np.arange(m) / (0.05 * n + 1))
    y = np.concatenate([env * np.sin(ph), (env[-1] * tail) * np.sin(ph[-1] + 2 * np.pi * f[-1] * np.arange(1, m + 1) / R)])
    pk = np.abs(y).max(); y = y / pk
    w = np.concatenate([env, env[-1] * tail]) ** 2; ff = np.concatenate([f, np.full(m, f[-1])])
    return dict(y=y, T=T, fmean=float(np.exp(np.sum(w * np.log(ff)) / np.sum(w))), f0=f[0], f1=f[-1],
                envf=np.concatenate([env, env[-1] * tail]) / pk, ff=ff)
SHAPES = None  # list of (r, c, p, dec): set by set_shapes()
FAM = None
def set_shapes(lst):
    global SHAPES, FAM
    SHAPES = list(lst); FAM = [dict(shape(*k), r=k[0], p=k[2]) for k in SHAPES]
def at_speed(s, sp):
    return np.interp(np.arange(0, len(s) - 1, sp), np.arange(len(s)), s)
TF_WIN, TF_HOP, TF_NFFT, TF_FMAX = 384, 48, 512, 7000
_tfw = hann_sym(TF_WIN)
def tf_mag(y):
    if len(y) < TF_WIN: y = np.pad(y, (0, TF_WIN - len(y)))
    nf = (len(y) - TF_WIN) // TF_HOP + 1
    fr = np.stack([y[j * TF_HOP:j * TF_HOP + TF_WIN] * _tfw for j in range(nf)])
    return np.abs(np.fft.rfft(fr, TF_NFFT, axis=1))
KMAX = int(TF_FMAX * TF_NFFT / R) + 1
def peaks_only(M):
    return M - median_axis(M, 9, 1)
MIN_LEN, MAX_LEN, SLACK = 0.7, 4.0, 0.012
def _tf_score(Mx, s, sp, j0, sl):
    Mb = tf_mag(at_speed(s['y'], sp))[:, :KMAX]; nb = len(Mb); best = None
    def dot(lag):
        X = Mx[lag:lag + nb, :KMAX]; return np.sum(X * Mb[:len(X)])
    lo, hi = max(0, j0 - sl), j0 + sl
    for lag in range(lo, hi + 1, 2):                      # coarse, then the neighbours of the best
        d = dot(lag)
        if best is None or d > best[0]: best = (d, lag)
    for lag in (best[1] - 1, best[1] + 1):
        if lo <= lag <= hi:
            d = dot(lag)
            if d > best[0]: best = (d, lag)
    d, lag = best; nn = np.sum(Mb * Mb)
    return d / np.sqrt(nn), lag, d / nn
NPRE = 12   # candidates scored exactly (after a cheap pre-score along each shape's own pitch path)
def _path2(s, sp, nfr):
    """per TF frame of the shape played at sp: the bin of its pitch and its envelope (from the shape's formula)"""
    tc = (np.arange(nfr) * TF_HOP + TF_WIN / 2) * sp
    idx = np.minimum(tc.astype(int), len(s['envf']) - 1)
    return np.round(s['ff'][idx] * sp * TF_NFFT / R).astype(int), s['envf'][idx]
def _pre_score(P3, s, sp, j0, sl):
    ny = int(np.ceil((len(s['y']) - 1) / sp)); nfr = (max(ny, TF_WIN) - TF_WIN) // TF_HOP + 1
    bins, e = _path2(s, sp, nfr)
    ok = (bins >= 1) & (bins <= KMAX - 2); js = np.nonzero(ok)[0]; bins, e = bins[ok], e[ok]
    if len(e) == 0: return -1e30
    ne = np.sqrt(np.sum(e * e))
    def dot(lag):
        jj = js + lag; m = jj < len(P3)
        return np.sum(e[m] * P3[jj[m], bins[m]])
    lo, hi = max(0, j0 - sl), j0 + sl; best = None
    for lag in range(lo, hi + 1, 2):
        d = dot(lag)
        if best is None or d > best: best = d
    return best / ne
def fit(Mx, sd, P3=None):
    j0 = int(sd['t0'] * R / TF_HOP); sl = int(SLACK * R / TF_HOP)
    if P3 is None: P3 = peak3_of(Mx)
    pre = []
    for i, s in enumerate(FAM):
        for cc in range(-300, 301, 50):
            sp = sd['fm'] / s['fmean'] * 2 ** (cc / 1200)
            if sp < 0.15 or sp > 6: continue
            T = s['T'] / sp
            if T < MIN_LEN * sd['d'] or T > MAX_LEN * sd['d'] + 0.03: continue
            pre.append((_pre_score(P3, s, sp, j0, sl), i, sp))
    if not pre: return None
    pre.sort(key=lambda q: -q[0])
    cand = []
    for _, i, sp in pre[:NPRE]:
        e, lag, amp = _tf_score(Mx, FAM[i], sp, j0, sl); cand.append((e, i, sp))
    cand.sort(key=lambda q: -q[0]); best = None
    for e0, i, sp0 in cand[:4]:
        for cc in (-20, -10, 0, 10, 20):
            sp = sp0 * 2 ** (cc / 1200)
            e, lag, amp = _tf_score(Mx, FAM[i], sp, j0, sl)
            if best is None or e > best[0]: best = (e, i, sp, lag, amp)
    e, i, sp, lag, amp = best
    return dict(t=int(lag * TF_HOP), shape=i, speed=float(sp), amp=float(amp), energy=float(e))
def peak3_of(Mx):
    P = Mx[:, :KMAX]
    return np.maximum(np.maximum(P, np.concatenate([P[:, 1:], P[:, -1:]], 1)), np.concatenate([P[:, :1], P[:, :-1]], 1))
def dedupe(bl):
    out = []
    for b in sorted(bl, key=lambda b: -b['energy']):
        s = FAM[b['shape']]; f0 = s['f0'] * b['speed']; T = s['T'] / b['speed']; same = False
        for o in out:
            so = FAM[o['shape']]; g0 = so['f0'] * o['speed']; To = so['T'] / o['speed']
            ov = min(b['t'] / R + T, o['t'] / R + To) - max(b['t'], o['t']) / R
            if abs(np.log(f0 / g0)) < 0.1 and ov > 0.6 * min(T, To): same = True; break
        if not same: out.append(b)
    return out
def bubble_wave(b, n):
    y = np.zeros(n); s = at_speed(FAM[b['shape']]['y'], b['speed']) * b['amp']; m = min(len(s), n - b['t'])
    if m > 0: y[b['t']:b['t'] + m] += s[:m]
    return y
# ---- checks: closer to the original where it plays (log-spectrogram footprint), and above chance (phase-randomised)
ACCEPT_DB, COHERENT_DB, N_SUR = 4.0, 6.0, 8
def _logspec_frames(y, j0, j1):
    """log magnitude of TF frames j0..j1-1 (as tf_mag over the whole signal would give)"""
    out = []
    for j in range(j0, j1):
        seg = y[j * TF_HOP:j * TF_HOP + TF_WIN]
        if len(seg) < TF_WIN: seg = np.pad(seg, (0, TF_WIN - len(seg)))
        out.append(np.abs(np.fft.rfft(seg * _tfw, TF_NFFT)))
    return 20 * np.log10(np.array(out) + 1e-7)
def _smooth3(L):
    P = np.concatenate([L[:1], L, L[-1:]]); return (P[:-2] + P[1:-1] + P[2:]) / 3
def gain_db(x, cur, b):
    n = len(x); s = bubble_wave(b, n)
    nfr = (n - TF_WIN) // TF_HOP + 1
    a = max(0, b['t'] // TF_HOP - 2); e = min(nfr, (b['t'] + len(at_speed(FAM[b['shape']]['y'], b['speed']))) // TF_HOP + 3)
    if e - a < 2: return -99.0
    Ms = 10 ** (_logspec_frames(s, a, e) / 20); fp = Ms > Ms.max() * 0.1
    fp[:, int(8000 * TF_NFFT / R):] = False
    if not fp.any(): return -99.0
    Lx = _smooth3(_logspec_frames(x, a, e)); L0 = _smooth3(_logspec_frames(cur, a, e)); L1 = _smooth3(_logspec_frames(cur + s, a, e))
    return float(np.mean(np.abs(Lx - L0)[fp]) - np.mean(np.abs(Lx - L1)[fp]))
def _best_proj(xa, sa, c, span=48):
    m = len(sa); best = 0.0; ns = np.sum(np.abs(sa) ** 2)
    for a in range(c - span, c + span + 1, 4):
        if a < 0 or a + m > len(xa): continue
        best = max(best, abs(np.vdot(sa, xa[a:a + m])) ** 2 / ns)
    return best
def surrogate_db(x, b, rng):
    s = at_speed(FAM[b['shape']]['y'], b['speed']); t = b['t']; n = len(x); m = min(len(s), n - t)
    if m < 64: return -99.0
    sa = analytic(s[:m]); p = int(0.03 * R); a0 = max(0, t - p); seg = x[a0:min(n, t + m + p)]; c = t - a0
    real = _best_proj(analytic(seg), sa, c)
    N = nextpow2(len(seg)); X = np.abs(np.fft.rfft(seg, N)); sur = 0.0
    for _ in range(N_SUR):
        ph = np.exp(2j * np.pi * rng.uniforms(len(X))); ph[0] = 1
        z = np.fft.irfft(X * ph, N)[:len(seg)]
        sur += _best_proj(analytic(z), sa, c)
    return float(10 * np.log10(real / (sur / N_SUR + 1e-20) + 1e-12))

# ---------------------------------------------------------------- 4. clicks
CB = [500, 1000, 2000, 4000, 8000]
TAUS = [0.0007, 0.002, 0.006]
RISE_DB = 9.0
def cband(y, c):
    return filtfilt(bp(c / 2 ** 0.5, min(c * 2 ** 0.5, 23000)), y)
def detect_clicks(xn):
    ev = []; h = 24
    for bi, c in enumerate(CB):
        b = cband(xn, c) ** 2
        e = np.add.reduceat(b, np.arange(0, len(b), h))
        bg = median1(e, 41) + 1e-14
        L = 10 * np.log10(e + 1e-14) - 10 * np.log10(bg)
        used = np.zeros(len(e), bool)
        for i in np.argsort(-e, kind='stable'):
            if L[i] < RISE_DB or used[max(0, i - 2):i + 3].any(): continue
            j = i
            while j + 1 < len(e) and j - i < 40 and L[j + 1] > 3: j += 1
            k = i
            while k - 1 >= 0 and i - k < 4 and L[k - 1] > 3: k -= 1
            E = float(np.sum(np.maximum(e[k:j + 1] - bg[k:j + 1], 0)))
            ex = np.maximum(e[i:j + 1] - bg[i:j + 1], 0); q = np.nonzero(ex < ex[0] * np.exp(-2))[0]
            dur = (q[0] if len(q) else len(ex)) * h / R
            ti = min(range(3), key=lambda T: abs(np.log(TAUS[T] / max(dur, 1e-4))))
            ev.append(dict(t=int(k * h), band=bi, tau=ti, var=len(ev) % 3, amp=float(np.sqrt(E))))
            used[k:j + 1] = True
    return ev
def burst(c, tau, seed):
    """the generic click files (unit energy); made once, uploaded; the encoder rebuilds the same waveforms"""
    n = int(tau * 7 * R) + 64
    z = Prng(int(c) * 100 + int(round(tau * 1e4)) * 10 + seed).normals(n + 2048)
    z = filtfilt(bp(c / 2 ** 0.5, min(c * 2 ** 0.5, 23000)), z)[1024:1024 + n]
    t = np.arange(n) / R; env = np.minimum(1, t / 0.0002) * np.exp(-t / tau)
    y = z * env; return y / np.sqrt(np.sum(y ** 2))
BURSTS = [[[burst(c, tau, s) for s in range(3)] for tau in TAUS] for c in CB]
def clicks_wave(ev, n):
    y = np.zeros(n)
    for e in ev:
        s = BURSTS[e['band']][e['tau']][e['var']] * e['amp']; m = min(len(s), n - e['t'])
        if m > 0: y[e['t']:e['t'] + m] += s[:m]
    return y

# ---------------------------------------------------------------- 5. grains
GB = [125 * 2 ** (i / 2) for i in range(-3, 12)]      # 44 .. 5657 Hz, half-octave
GMULT = 1.0
GMULT_HIGH = None  # grain length factor for bands from 2 kHz (None: GMULT)
def g_real(c):
    return (GMULT_HIGH if (GMULT_HIGH is not None and c >= 1900) else GMULT) * (0.007 if c >= 500 else (0.010 if c >= 200 else (0.025 if c >= 100 else 0.040)))
def gband(c):
    return bp(c / 2 ** 0.25, min(c * 2 ** 0.25, 8000 * 0.99))
UNIT = None   # per band: steady band power of the band's grain stream at volume 1 (from the grain files)
def grain_levels(target, minus):
    """per band: grain volumes on the band's fixed grid (t = k * G/2)"""
    out = []
    for bi, c in enumerate(GB):
        G = g_real(c); hop = G / 2
        xb = filtfilt(gband(c), target) ** 2; tb = filtfilt(gband(c), minus) ** 2
        g = int(G * R); w = np.sin(np.pi * (np.arange(g) + 0.5) / g) ** 2; w /= w.sum()
        vols = []; k = 0
        while k * hop < len(target) / R:
            a = int(k * hop * R); m = min(g, len(xb) - a)
            px, pt = np.dot(xb[a:a + m], w[:m]), np.dot(tb[a:a + m], w[:m])
            p = max(px - pt, 0.05 * px)
            vols.append(np.sqrt(p / UNIT[bi]) if p > 1e-12 else 0.0); k += 1
        out.append(np.array(vols))
    return out

# ---------------------------------------------------------------- 6. top cutoff
def top_cutoff(x, drop_db=15.0):
    N = 4096; w = hann_per(N); H = N // 2
    if len(x) < N: x = np.pad(x, (0, N - len(x)))
    p = np.zeros(N // 2 + 1); k = 0
    for s in range(0, len(x) - N + 1, H):
        p += np.abs(np.fft.rfft(x[s:s + N] * w)) ** 2; k += 1
    L = 10 * np.log10(p / k + 1e-20); f = np.arange(N // 2 + 1) * R / N
    def lv(q): return L[(f >= q / 2 ** (1 / 12)) & (f <= q * 2 ** (1 / 12))].mean()
    q = 3000.0
    while q * 2 ** (1 / 3) < 20000:
        if lv(q * 2 ** (1 / 3)) < lv(q) - drop_db: return min(q * 2 ** (1 / 6), 7800.0)
        q *= 2 ** (1 / 24)
    return 7800.0

# ---------------------------------------------------------------- the encoder
LOW_AS_NOISE, EQ_CAP_DB = 400.0, 10.0
NOISE_FROM_FULL = True
def encode(x, seed=1):
    n = len(x); rng = Prng(seed)
    xt, xn = split(x)
    clicks = detect_clicks(xn); yc = clicks_wave(clicks, n)
    target = xn + filtfilt(lp(LOW_AS_NOISE), xt)
    vols = grain_levels(target, yc)
    noise = target  # what the clicks + grains will carry (they are fitted to it): the bubble checks and level match use it
    # bubbles: fit, dedupe, keep the ones that pass both checks (strongest first)
    if FAST:
        P3 = peak3(tf_mag(x)); cand = dedupe([b for b in (fit_fast(P3, s) for s in seeds(x)) if b])
    else:
        Mx = tf_mag(x); Mx = Mx - median_axis(Mx, PK_FLOOR, 1); P3 = peak3_of(Mx)
        cand = dedupe([b for b in (fit(Mx, s, P3) for s in seeds(x)) if b])
    kept = []; cur = noise.copy()
    for b in sorted(cand, key=lambda b: -b['energy']):
        if gain_db(x, cur, b) > ACCEPT_DB and surrogate_db(x, b, rng) > COHERENT_DB:
            kept.append(b); cur = cur + bubble_wave(b, n)
    yb = cur - noise
    if NOISE_FROM_FULL:
        # the grains follow the whole original, minus what the clicks and the kept bubbles carry (5 ms envelopes of the full
        # sound per half-octave: the noise part alone misses everything the split calls "tone" but no bubble took)
        vols = grain_levels(x, yc + yb)
        return dict(n=n, fc=top_cutoff(x), bubbles=kept, clicks=clicks, grains=vols, cand=len(cand))
    # per-band level match: noise volumes so bubbles + noise carry the original's band energy
    eq = []
    for bi, c in enumerate(GB):
        sos = bp(c / 2 ** 0.25, min(c * 2 ** 0.25, 23000))
        want = np.sum(filtfilt(sos, x) ** 2) - np.sum(filtfilt(sos, yb) ** 2)
        have = np.sum(filtfilt(sos, noise) ** 2)
        eq.append(float(np.clip(np.sqrt(max(want, 1e-14) / max(have, 1e-14)), 10 ** (-EQ_CAP_DB / 20), 10 ** (EQ_CAP_DB / 20))))
    vols = [v * g for v, g in zip(vols, eq)]
    gb = np.array(GB); lg = np.log(eq)
    for e in clicks:
        c = CB[e['band']]; m = (gb >= c / 2 ** 0.5) & (gb <= c * 2 ** 0.5)
        if m.any(): e['amp'] *= float(np.exp(lg[m].mean()))
    return dict(n=n, fc=top_cutoff(x), bubbles=kept, clicks=clicks, grains=vols, cand=len(cand))

# ---------------------------------------------------------------- offline playback model (game rules live in the Player)
GRAIN_SRC = None   # per band: the band's grain source (clean noise, crackle above 1 kHz), played at speed 1 here
def grains_wave(vols, n):
    y = np.zeros(n + R)
    for bi, c in enumerate(GB):
        G = g_real(c); g = int(G * R); hop = G / 2; w = np.sin(np.pi * (np.arange(g) + 0.5) / g)
        src = GRAIN_SRC[bi]; rng = np.random.default_rng(bi)
        for k, v in enumerate(vols[bi]):
            if v <= 0: continue
            o = rng.integers(0, len(src) - g); a = int(round(k * hop * R))
            y[a:a + g] += src[o:o + g] * w * v
    return y[:n]
def render(enc, fc=None):
    n = enc['n']; y = clicks_wave(enc['clicks'], n) + grains_wave(enc['grains'], n)
    for b in enc['bubbles']: y += bubble_wave(b, n)
    from scipy.signal import sosfilt as sf
    fc = fc or enc['fc']
    return sf(lp(fc), sf(lp(fc), y))
def init_sources():
    """grain sources and their unit powers, as the grain module builds them (clean band noise; crackle >= 1 kHz)"""
    global GRAIN_SRC, UNIT
    import grain as G, x5
    GRAIN_SRC, UNIT = [], []
    for c in GB:
        F, sp = G.file_for(c); x = F['src']; L = len(x)
        y = np.interp(np.arange(0, L - 1, sp), np.arange(L), x)
        GRAIN_SRC.append(y)
        UNIT.append(float(np.mean(filtfilt(gband(c), np.tile(y, 2))[len(y) // 2:len(y) // 2 + len(y)] ** 2)))

# ---------------------------------------------------------------- fast fit (what Luau runs): sample the sound's peak map
# along the shape's own pitch path instead of correlating spectrograms. Score = sum over frames of env * peak(t, f(t)),
# divided by sqrt(sum env^2): a matched filter on the ridge. peak(t, f) = max of the 3 bins around f.
_WSUM = float(_tfw.sum())
def _path(s, sp):
    """per TF frame of the blip played at sp: (bin of its pitch, envelope weight)"""
    if 'env' not in s:
        y = s['y']; n = len(y); T = s['T']; tt = np.arange(n) / R
        f_file = 1000.0 * s['r'] ** (np.minimum(tt / T, 1) ** s['p'])
        s['env'] = np.abs(analytic(y)); s['ff'] = f_file
    L = len(s['y']) / sp; nfr = max(1, int((L - TF_WIN) // TF_HOP) + 1)
    tc = (np.arange(nfr) * TF_HOP + TF_WIN / 2) * sp              # frame centre in file samples
    idx = np.minimum(tc.astype(int), len(s['y']) - 1)
    return np.round(s['ff'][idx] * sp * TF_NFFT / R).astype(int), s['env'][idx]
def _ridge_score(P3, s, sp, j0, sl):
    bins, e = _path(s, sp); ok = bins < KMAX - 1; bins, e = bins[ok], e[ok]
    if len(e) == 0: return -1e9, j0, 0
    js = np.arange(len(e)); best = None; ne = np.sum(e * e)
    for lag in range(max(0, j0 - sl), j0 + sl + 1):
        jj = js + lag; m = jj < len(P3)
        d = np.sum(e[m] * P3[jj[m], bins[m]])
        if best is None or d > best[0]: best = (d, lag)
    d, lag = best
    return d / np.sqrt(ne), lag, d / ne / (_WSUM / 2)
def fit_fast(P3, sd):
    j0 = int(sd['t0'] * R / TF_HOP); sl = int(SLACK * R / TF_HOP)
    cand = []
    for i, s in enumerate(FAM):
        for cc in range(-300, 301, 25):
            sp = sd['fm'] / s['fmean'] * 2 ** (cc / 1200)
            if sp < 0.15 or sp > 6: continue
            T = s['T'] / sp
            if T < MIN_LEN * sd['d'] or T > MAX_LEN * sd['d'] + 0.03: continue
            e, lag, amp = _ridge_score(P3, s, sp, j0, sl); cand.append((e, i, sp))
    if not cand: return None
    cand.sort(key=lambda q: -q[0]); best = None
    for e0, i, sp0 in cand[:4]:
        for cc in (-10, -5, 0, 5, 10):
            sp = sp0 * 2 ** (cc / 1200)
            e, lag, amp = _ridge_score(P3, FAM[i], sp, j0, sl)
            if best is None or e > best[0]: best = (e, i, sp, lag, amp)
    e, i, sp, lag, amp = best
    return dict(t=int(lag * TF_HOP), shape=i, speed=float(sp), amp=float(amp), energy=float(e))
def peak3(M):
    P = M - median_axis(M, 9, 1)
    return np.maximum(np.maximum(P, np.concatenate([P[:, 1:], P[:, -1:]], 1)), np.concatenate([P[:, :1], P[:, :-1]], 1))
FAST = False
PK_FLOOR = 21   # bins (~2 kHz): wide enough that a fast sweep, smeared over many bins, is not taken for floor

# the generic tone shapes (one packed upload): (glide ratio, cycles, curve, decay dB)
PLAIN = [(r, c, 1.0, 26.0) for r in (0.8, 0.9, 1.0, 1.12, 1.25, 1.6, 2.0) for c in (8, 12, 18, 25, 35, 50, 70, 100)]
HOOKS = [(r, c, p, d) for r in (1.5, 2.0, 3.0, 4.0) for p in (2.0, 3.0) for c in (25, 35, 50, 70) for d in (10.0, 26.0)]
DEFAULT_SHAPES = PLAIN + HOOKS

# ================================================================ v2 grains: two band sets
#   half-octave set: the 15 bands above (crackle grains from 1 kHz), weight 0.3 below 2 kHz, 1.0 above (0.65 at 2 kHz)
#   sixth-octave set: 40 Hz .. 2 kHz, smooth noise, weight 0.7
# every grain twice as long as v1; grain levels follow the whole sound minus the clicks and kept bubbles
SIXTH = [40 * 2 ** (k / 6) for k in range(64) if 40 * 2 ** (k / 6) < 2000]
def _hw(c):
    return 0.3 if c < 1900 else (0.65 if c < 2100 else 1.0)
BANDS2 = [dict(c=c, lo=c / 2 ** 0.25, hi=min(c * 2 ** 0.25, 8000 * 0.99), w=_hw(c), kind='half', hb=i) for i, c in enumerate(GB)] + \
         [dict(c=c, lo=c / 2 ** (1 / 12), hi=c * 2 ** (1 / 12), w=0.7, kind='sixth') for c in SIXTH]
G2MULT = 2.0
def g2(c):
    return G2MULT * (0.007 if c >= 500 else (0.010 if c >= 200 else (0.025 if c >= 100 else 0.040)))
SRC2 = None; UNIT2 = None
def init_sources2():
    """the grain source of every band (half set: the v1 sources; sixth set: band-limited Gaussian noise) and its unit power"""
    global SRC2, UNIT2
    if GRAIN_SRC is None: init_sources()
    SRC2, UNIT2 = [], []
    for k, b in enumerate(BANDS2):
        sos = bp(b['lo'], b['hi'])
        if b['kind'] == 'half':
            src = GRAIN_SRC[b['hb']]; SRC2.append(src); UNIT2.append(UNIT[b['hb']]); continue
        z = np.random.default_rng(1000 + k).standard_normal(R * 3)
        src = filtfilt(sos, z); src /= np.sqrt(np.mean(src ** 2)) * 4  # (peak headroom for the upload file)
        SRC2.append(src); y = filtfilt(sos, np.tile(src, 2)); L = len(src)
        UNIT2.append(float(np.mean(y[L // 2:L // 2 + L] ** 2)))
def grain_levels2(target, minus):
    out = []
    for k, b in enumerate(BANDS2):
        G = g2(b['c']); hop = G / 2; sos = bp(b['lo'], b['hi'])
        xb = filtfilt(sos, target) ** 2; tb = filtfilt(sos, minus) ** 2
        g = int(G * R); w = np.sin(np.pi * (np.arange(g) + 0.5) / g) ** 2; w /= w.sum()
        vols = []; i = 0; sw = np.sqrt(b['w'])
        while i * hop < len(target) / R:
            a = int(i * hop * R); m = min(g, len(xb) - a)
            px, pt = np.dot(xb[a:a + m], w[:m]), np.dot(tb[a:a + m], w[:m])
            p = max(px - pt, 0.05 * px)
            vols.append(np.sqrt(p / UNIT2[k]) * sw if p > 1e-12 else 0.0); i += 1
        out.append(np.array(vols))
    return out
def grains_wave2(vols, n):
    y = np.zeros(n + R)
    for k, b in enumerate(BANDS2):
        G = g2(b['c']); g = int(G * R); hop = G / 2; w = np.sin(np.pi * (np.arange(g) + 0.5) / g)
        src = SRC2[k]; rng = np.random.default_rng(k)
        for i, v in enumerate(vols[k]):
            if v <= 0: continue
            o = rng.integers(0, len(src) - g); a = int(round(i * hop * R))
            y[a:a + g] += src[o:o + g] * w * v
    return y[:n]
def encode2(x, seed=1):
    n = len(x); rng = Prng(seed)
    xt, xn = split(x)
    clicks = detect_clicks(xn); yc = clicks_wave(clicks, n)
    noise = xn + filtfilt(lp(LOW_AS_NOISE), xt)   # (the bubble checks compare against this)
    Mx = tf_mag(x); Mx = Mx - median_axis(Mx, PK_FLOOR, 1); P3 = peak3_of(Mx)
    cand = dedupe([b for b in (fit(Mx, s, P3) for s in seeds(x)) if b])
    kept = []; cur = noise.copy()
    for b in sorted(cand, key=lambda b: -b['energy']):
        if gain_db(x, cur, b) > ACCEPT_DB and surrogate_db(x, b, rng) > COHERENT_DB:
            kept.append(b); cur = cur + bubble_wave(b, n)
    yb = cur - noise
    vols = grain_levels2(x, yc + yb)
    return dict(n=n, fc=top_cutoff(x), bubbles=kept, clicks=clicks, grains=vols, cand=len(cand), v=2)
def render2(enc, fc=None):
    n = enc['n']; y = clicks_wave(enc['clicks'], n) + grains_wave2(enc['grains'], n)
    for b in enc['bubbles']: y += bubble_wave(b, n)
    from scipy.signal import sosfilt as sf
    fc = fc or enc['fc']
    return sf(lp(fc), sf(lp(fc), y))
