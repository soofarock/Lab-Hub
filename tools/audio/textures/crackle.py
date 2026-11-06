# Generic "crackle" noise loops: octave-band noise made of sparse random clicks (same band and RMS as the smooth noise
# loops), at a few densities; and a re-render of a clip's events with crackle in the noise bands above a split frequency.
import sys, os, numpy as np
from scipy.signal import butter, sosfiltfilt
from scipy.stats import kurtosis
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import render as RN
R = 48000
def make(src_name, rate, seconds=3.0, seed=3):
    """same octave band as src (its spectrum), built from Poisson clicks at `rate` per second"""
    x, L, sr = RN.asset(src_name); x = x[1:L + 1]
    n = int(seconds * R); rng = np.random.default_rng(seed)
    imp = np.zeros(n)
    k = rng.poisson(rate * seconds)
    pos = rng.integers(0, n, k); amp = rng.standard_normal(k) * rng.exponential(1.0, k)
    np.add.at(imp, pos, amp)
    # shape to the source loop's own spectrum (circular, so the loop stays seamless)
    S = np.abs(np.fft.rfft(np.resize(x, n)))
    Y = np.fft.rfft(imp) / (np.abs(np.fft.rfft(imp)) + 1e-9) * S  # phases from the clicks, magnitude of the band
    # keep the clicks' time structure: filter the clicks by the band's average magnitude instead
    H = np.convolve(S, np.ones(31) / 31, 'same')
    y = np.fft.irfft(np.fft.rfft(imp) * H, n)
    y *= np.sqrt(np.mean(x ** 2)) / np.sqrt(np.mean(y ** 2))
    return y
def kurt20(y):
    w = int(0.02 * R); return np.median([kurtosis(y[i:i + w], fisher=False) for i in range(0, len(y) - w, w)])
if __name__ == '__main__':
    for src in ('noise_6_4000', 'noise_4_1000'):
        x, L, sr = RN.asset(src)
        print(src, 'smooth kurtosis %.1f' % kurt20(x[1:L + 1]), ' '.join('rate %d: %.1f' % (r, kurt20(make(src, r))) for r in (200, 500, 1000, 2000, 5000)))
