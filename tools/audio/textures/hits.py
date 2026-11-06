# Hit layer: onsets of the original rebuilt as generic noise bursts (burst_<band>_t6/t25) placed at their exact time.
import sys, numpy as np, render as RN
from scipy.optimize import nnls
from scipy.signal import butter, sosfiltfilt
R = 48000
BURSTS = ['burst_%s_t%d' % (b, t) for b in ('1000', '2000', '4000', '8000', 'wide') for t in (6, 25)]
OCT = [(500, 1000), (1000, 2000), (2000, 4000), (4000, 7800)]
def band_e(x):
    return np.array([np.sum(sosfiltfilt(butter(4, b, 'bandpass', fs=R, output='sos'), x) ** 2) for b in OCT])
def env(z, ms=2.5):
    k = int(ms / 1000 * R); return 10 * np.log10(np.convolve(z ** 2, np.ones(k) / k, 'same')[::k] + 1e-12), k
def detect(o, rise=8):
    e, k = env(o)
    h = np.nonzero(np.diff(e) > rise)[0] + 1
    keep = []
    for i in h:
        if not keep or i - keep[-1] > 4: keep.append(i)
    return [i * k for i in keep]
def add_hits(o, y, win=0.010, nyq=7800):
    out = y.copy()
    shapes = {}
    for b in BURSTS:
        x, L, sr = RN.asset(b); x = x[1:L + 1]
        if b.startswith('burst_8000') or b.startswith('burst_wide'):
            x = sosfiltfilt(butter(6, nyq, 'lowpass', fs=R, output='sos'), x)  # the recording's band only
        shapes[b] = x
    n = int(win * R)
    hits = detect(o)
    for t in hits:
        pre = max(t - n, 0)
        need = band_e(o[t:t + n]) - band_e(y[t:t + n])  # what the hit adds that ours lacks
        need = np.maximum(need, 0)
        if need.sum() <= 0: continue
        A = np.array([band_e(shapes[b][:n]) for b in BURSTS]).T
        g, _ = nnls(A, need)
        for b, gi in zip(BURSTS, g):
            if gi > 0:
                s = shapes[b] * np.sqrt(gi); m = min(len(s), len(out) - t); out[t:t + m] += s[:m]
    return out, hits
if __name__ == '__main__':
    OUT = '../sf_out/sweep'; tag = sys.argv[1]
    o = RN.readwav(f'{OUT}/{tag}_original.wav')[0][:, 0]; y = RN.readwav(f'{OUT}/{tag}_now_crackle.wav')[0][:, 0]
    z, hits = add_hits(o, y)
    RN.writewav(f'{OUT}/{tag}_crackle_hits.wav', z)
    e_o, _ = env(o, 5); e_y, _ = env(y, 5); e_z, _ = env(z, 5)
    m = e_o > e_o.max() - 40
    print(tag, 'hits placed %d | sharp hits orig %d, crackle %d, crackle+hits %d | 5ms level err %.1f -> %.1f dB' % (
        len(hits), np.sum(np.diff(e_o) > 10), np.sum(np.diff(e_y) > 10), np.sum(np.diff(e_z) > 10), np.mean(np.abs(e_o - e_y)[m]), np.mean(np.abs(e_o - e_z)[m])))
