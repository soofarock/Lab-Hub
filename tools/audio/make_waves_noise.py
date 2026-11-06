# Generates the AudioLab WaveBank assets. Must match ReplicatedStorage.AudioLab.Codec.WaveBank (Version 1).
import math, struct, numpy as np

RATE = 44100
BASES = [55, 220, 880, 3520]
MAX_SPEED = 2
WAVES = [
    ("sine", "sine", None, 0.9),
    ("triangle", "triangle", None, 0.9),
    ("saw", "saw", None, 0.75),
    ("square", "pulse", 0.5, 0.75),
    ("pulse25", "pulse", 0.25, 0.5),
    ("pulse12", "pulse", 0.125, 0.47),
]
NOISE_CENTERS = [125, 250, 500, 1000, 2000, 4000, 8000, 16000]
NOISE_RMS = 0.2
NOISE_LEN = 65536

def harmonic(kind, duty, k):
    if kind == "sine":
        return (1.0, 0.0) if k == 1 else (0.0, 0.0)
    if kind == "triangle":
        if k % 2 == 0: return (0.0, 0.0)
        a = 8 / (math.pi ** 2 * k * k)
        return (a if ((k - 1) // 2) % 2 == 0 else -a, 0.0)
    if kind == "saw":
        a = 2 / (math.pi * k)
        return (a if k % 2 == 1 else -a, 0.0)
    if kind == "pulse":
        c = 4 / (math.pi * k) * math.sin(math.pi * k * duty)
        return (0.0, 0.0) if abs(c) < 1e-12 else (0.0, c)
    raise ValueError(kind)

def write_wav(path, x):
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2").tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16))
        f.write(b"data" + struct.pack("<I", len(pcm)) + pcm)

report = []
t = np.arange(RATE) / RATE  # exactly 1 second
for name, kind, duty, gain in WAVES:
    for base in BASES:
        H = max(1, (RATE // 2) // (base * MAX_SPEED))
        x = np.zeros(RATE)
        for k in range(1, H + 1):
            s, c = harmonic(kind, duty, k)
            if s: x += s * np.sin(2 * np.pi * k * base * t)
            if c: x += c * np.cos(2 * np.pi * k * base * t)
        x *= gain
        fname = f"wave_{name}_{base}.wav"
        write_wav(fname, x)
        # seam check: the sample after the last one must equal the first (integer cycles)
        nxt = sum((harmonic(kind, duty, k)[0] * math.sin(2*math.pi*k*base) + harmonic(kind, duty, k)[1] * math.cos(2*math.pi*k*base)) for k in range(1, H+1)) * gain
        report.append(f"{fname:26s} harmonics={H:3d} peak={np.abs(x).max():.3f} seam_err={abs(nxt - x[0]):.1e}")

for i, c in enumerate(NOISE_CENTERS, start=1):
    low, high = c / math.sqrt(2), min(c * math.sqrt(2), RATE / 2)
    lo = max(1, math.ceil(low * NOISE_LEN / RATE)); hi = min(NOISE_LEN // 2 - 1, math.floor(high * NOISE_LEN / RATE))
    rng = np.random.default_rng(1000 + i)
    spec = np.zeros(NOISE_LEN // 2 + 1, dtype=complex)
    spec[lo:hi + 1] = np.exp(1j * rng.uniform(0, 2 * np.pi, hi - lo + 1))
    x = np.fft.irfft(spec, NOISE_LEN)   # circular -> seamless loop
    x *= NOISE_RMS / np.sqrt(np.mean(x ** 2))
    fname = f"noise_{i}_{c}.wav"
    write_wav(fname, x)
    report.append(f"{fname:26s} band={low:7.1f}-{high:7.1f} Hz peak={np.abs(x).max():.3f} rms={np.sqrt(np.mean(x**2)):.3f}")
print("\n".join(report))
