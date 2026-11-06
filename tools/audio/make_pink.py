# Generic pink-noise loop for AudioLab (file pink_noise.wav): equal energy per octave from 20 Hz to 20 kHz, built as one
# circular spectrum so the loop has no seam, 3 s, 48 kHz mono 16-bit, RMS 0.2 (WaveBank.NoiseRms, like the band loops).
# The breath / air source of the source-filter voices: AudioFilters shape it per block. The seed is the first one whose
# peak is <= 0.82 (headroom; noise's peak is otherwise random).
import numpy as np, wave
R, SECS, LO, HI, RMS = 48000, 3.0, 20.0, 20000.0, 0.2
N = int(R * SECS)
f = np.fft.rfftfreq(N, 1 / R)
mag = np.zeros_like(f)
band = (f >= LO) & (f <= HI)
mag[band] = 1 / np.sqrt(f[band])          # power ~ 1/f: pink
for seed in range(1, 500):
    rng = np.random.default_rng(seed)
    X = mag * np.exp(2j * np.pi * rng.random(len(f)))
    x = np.fft.irfft(X, N)
    x *= RMS / np.sqrt(np.mean(x ** 2))
    if np.abs(x).max() <= 0.82:
        break
q = np.round(x * 32767).astype('<i2')
with wave.open('pink_noise.wav', 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(R); w.writeframes(q.tobytes())
y = q / 32768
P = np.abs(np.fft.rfft(y)) ** 2
bands = [10 * np.log10(P[(f >= c / 2 ** 0.5) & (f < c * 2 ** 0.5)].sum()) for c in (31.5, 125, 500, 2000, 8000, 16000)]
d = np.abs(np.diff(np.concatenate([y, y[:1]])))
print('seed %d  rms %.3f  peak %.3f  octave levels %s dB  loop step %.4f (largest step %.4f)' % (
    seed, np.sqrt(np.mean(y ** 2)), np.abs(y).max(), ' '.join('%.1f' % b for b in bands), d[-1], d.max()))
