# AudioLab WaveBank v2 additions: harmonic bundles + half-octave-offset noise bands.
# Must match ReplicatedStorage.AudioLab.Codec.WaveBank (Version 2).
import math, struct, sys, numpy as np

RATE = 44100
OUT = sys.argv[1] if len(sys.argv) > 1 else "."
# Harmonic bundles: one player carries a whole octave of harmonics. Each asset is rendered at the TOP
# of its note octave and only ever played at speed <= 1, so nothing can alias above 20 kHz.
BUNDLE_BASES = [110, 220, 440, 880, 1760]
BUNDLE_GROUPS = [(9, 16), (17, 32), (33, 64), (65, 128)]   # g1..g4
BUNDLE_TOP_HZ = 20000
BUNDLE_TILT = 1.0          # amplitude of harmonic k inside a bundle ~ 1/k^TILT
BUNDLE_RMS = 0.25
# Noise: 8 new octave-wide bands centred half an octave above the existing ones (overlapping filterbank)
NOISE_CENTERS2 = [88, 177, 354, 707, 1414, 2828, 5657, 11314]
NOISE_RMS = 0.2
NOISE_LEN = 65536

def write_wav(path, x):
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2").tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16))
        f.write(b"data" + struct.pack("<I", len(pcm)) + pcm)

def low_crest_phases(amps):
    # Schroeder phases generalised to arbitrary amplitudes (low peak-to-RMS for a harmonic sum)
    p = amps ** 2 / np.sum(amps ** 2)
    ph = np.zeros(len(amps)); acc = 0.0
    for i in range(1, len(amps)):
        acc += p[i - 1]
        ph[i] = ph[i - 1] - 2 * np.pi * acc
    return ph

report = []
t = np.arange(RATE) / RATE
for base in BUNDLE_BASES:
    for g, (k0, k1) in enumerate(BUNDLE_GROUPS, start=1):
        kmax = min(k1, BUNDLE_TOP_HZ // base)
        if kmax < k0:
            continue
        ks = np.arange(k0, kmax + 1)
        amps = ks.astype(float) ** -BUNDLE_TILT
        ph = low_crest_phases(amps)
        x = np.zeros(RATE)
        for k, a, p in zip(ks, amps, ph):
            x += a * np.cos(2 * np.pi * k * base * t + p)
        x *= BUNDLE_RMS / np.sqrt(np.mean(x ** 2))
        name = f"bundle_g{g}_{base}.wav"
        write_wav(f"{OUT}/{name}", x)
        nxt = sum(a * math.cos(2 * math.pi * k * base + p) for k, a, p in zip(ks, amps, ph)) * BUNDLE_RMS / np.sqrt(np.mean((x / (BUNDLE_RMS / np.sqrt(np.mean(x**2))))**2))
        report.append(f"{name:24s} harmonics {k0}-{kmax:<3d} ({k0*base}-{kmax*base} Hz) peak={np.abs(x).max():.3f} rms={np.sqrt(np.mean(x**2)):.3f}")

for i, c in enumerate(NOISE_CENTERS2, start=9):
    low, high = c / math.sqrt(2), min(c * math.sqrt(2), RATE / 2)
    lo = max(1, math.ceil(low * NOISE_LEN / RATE)); hi = min(NOISE_LEN // 2 - 1, math.floor(high * NOISE_LEN / RATE))
    rng = np.random.default_rng(1000 + i)
    spec = np.zeros(NOISE_LEN // 2 + 1, dtype=complex)
    spec[lo:hi + 1] = np.exp(1j * rng.uniform(0, 2 * np.pi, hi - lo + 1))
    x = np.fft.irfft(spec, NOISE_LEN)
    x *= NOISE_RMS / np.sqrt(np.mean(x ** 2))
    name = f"noise_{i}_{c}.wav"
    write_wav(f"{OUT}/{name}", x)
    report.append(f"{name:24s} band {low:7.1f}-{high:7.1f} Hz peak={np.abs(x).max():.3f} rms={np.sqrt(np.mean(x**2)):.3f}")
print("\n".join(report)); print(len(report), "files")
