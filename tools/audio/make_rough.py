# Generic "rough sine" (rough_880): noise centred on 880 Hz with a Gaussian width of 3% (sigma); the synth plays it per
# harmonic for the fast roughness a steady sine can't carry. Built as one circular spectrum, so the file loops with no
# seam. 48 kHz mono 16-bit, RMS 0.25.
import numpy as np, wave
R, BASE, WIDTH, SECS, RMS = 48000, 880.0, 0.03, 3.9, 0.25
N = int(SECS * R)
f = np.fft.rfftfreq(N, 1 / R)
H = np.exp(-0.5 * ((f - BASE) / (WIDTH * BASE)) ** 2)
rng = np.random.default_rng(880)
X = H * np.exp(2j * np.pi * rng.random(len(f)))
x = np.fft.irfft(X, N)
x *= RMS / np.sqrt(np.mean(x ** 2))
print('peak %.3f rms %.3f' % (np.abs(x).max(), np.sqrt(np.mean(x ** 2))))
assert np.abs(x).max() < 0.99
# seam check: the loop's wrap is just another sample step
d = np.abs(np.diff(np.concatenate([x, x[:1]])))
print('largest step %.4f, step at the loop point %.4f' % (d.max(), d[-1]))
with wave.open('rough_880.wav', 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(R)
    w.writeframes(np.round(x * 32767).astype('<i2').tobytes())
# the centre and width of the file written
y = np.frombuffer(open('rough_880.wav', 'rb').read()[44:], '<i2') / 32767
S = np.abs(np.fft.rfft(y)) ** 2; fr = np.fft.rfftfreq(len(y), 1 / R)
c = np.sum(fr * S) / np.sum(S); sd = np.sqrt(np.sum((fr - c) ** 2 * S) / np.sum(S))
print('centre %.1f Hz, power-sigma %.1f Hz (%.1f%%)' % (c, sd, 100 * sd / c))
