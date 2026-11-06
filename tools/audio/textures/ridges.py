# Tone layer with a short window: ridge tracking that follows fast glides (bubbles), resynthesised as gliding sines.
import numpy as np
from scipy.signal import butter, sosfiltfilt
R = 48000
def track(x, win=1024, hop=128, fmin=300, fmax=7000, prom_db=10, max_jump=0.12, min_frames=6):
    w = np.hanning(win); nfft = 4096
    f = np.fft.rfftfreq(nfft, 1 / R)
    lo, hi = np.searchsorted(f, fmin), np.searchsorted(f, fmax)
    frames = []
    for s in range(0, len(x) - win, hop):
        X = np.abs(np.fft.rfft(x[s:s + win] * w, nfft)); P = 20 * np.log10(X + 1e-12)
        pk = []
        for i in range(lo + 1, hi - 1):
            if P[i] > P[i - 1] and P[i] >= P[i + 1]:
                nb = P[max(lo, i - 40):i - 8].tolist() + P[i + 9:min(hi, i + 41)].tolist()
                if nb and P[i] - np.median(nb) > prom_db:
                    # parabolic interpolation
                    a, b, c = P[i - 1], P[i], P[i + 1]; d = 0.5 * (a - c) / (a - 2 * b + c)
                    amp = 10 ** ((b - 0.25 * (a - c) * d) / 20) * 2 / w.sum()
                    pk.append(((i + d) * R / nfft, amp))
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
    return [t for t in tracks if len(t['f']) >= min_frames], hop, win
def synth(tracks, hop, win, n):
    y = np.zeros(n)
    for t in tracks:
        k = len(t['f']); t0 = t['start'] * hop + win // 2
        tt = np.arange(k * hop)
        fi = np.interp(tt, np.arange(k) * hop, t['f']); ai = np.interp(tt, np.arange(k) * hop, t['a'])
        # fade in / out over one hop
        fade = np.minimum(1, np.minimum((tt + 1) / hop, (k * hop - tt) / hop))
        ph = 2 * np.pi * np.cumsum(fi) / R
        seg = ai * fade * np.sin(ph)
        a = t0 - hop // 2; b = min(n, a + len(seg))
        if a < 0: seg = seg[-a:]; a = 0
        y[a:b] += seg[:b - a]
    return y
