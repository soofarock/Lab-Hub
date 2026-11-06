# Renders AudioLab playback event lists to audio, with a model of the Roblox audio engine:
#   * output 48 kHz, processed in 1024-sample blocks; a property write made while block b is being prepared lands on the
#     boundary that starts block b+1 (an event list gives the block index b of each write)
#   * PlaybackSpeed is held for a whole block (phase continuous); Volume steps on the boundary, with an optional short
#     linear de-click ramp (RAMP samples; default 64 = 1.3 ms)
#   * TimePosition / Play / Stop take effect on the boundary
#   * each uploaded asset = its WAV (assets/audio) looped, read with 4-point cubic interpolation, times
#     the file's playback level (WaveBank.NoiseGainFile / BundleGain: the pool divides by these)
import numpy as np, wave, os, re, sys
R = 48000
BLK = 1024
HERE = os.path.dirname(os.path.abspath(__file__))
ASSET_DIR = os.path.join(HERE, '..', '..', '..', 'assets', 'audio')  # the generic uploads
NOISE_FILE_GAIN = {'noise_4_1000': 0.985, 'noise_6_4000': 0.942}
NOISE_GAIN_ALL = [0.985, 1.023, 0.997, 0.985, 0.962, 0.942, 0.872, 0.636, 0.957, 1.004, 1.037, 0.985, 0.978, 0.933, 0.910, 0.771]
NOISE_CENTERS = [125, 250, 500, 1000, 2000, 4000, 8000, 16000, 88, 177, 354, 707, 1414, 2828, 5657, 11314]
for i, c in enumerate(NOISE_CENTERS):
    NOISE_FILE_GAIN['noise_%d_%d' % (i + 1, c)] = NOISE_GAIN_ALL[i]
BUNDLE_GAIN = {101: 0.994, 102: 0.987, 103: 0.957, 104: 0.841, 105: 0.644, 201: 0.969, 202: 0.953, 203: 0.846, 204: 0.653,
               301: 0.938, 302: 0.846, 303: 0.656, 401: 0.827, 402: 0.658}
BBASE = {110: 1, 220: 2, 440: 3, 880: 4, 1760: 5}
_assets = {}

def readwav(p):
    w = wave.open(p)
    n, ch, sw, sr = w.getnframes(), w.getnchannels(), w.getsampwidth(), w.getframerate()
    raw = w.readframes(n)
    if sw == 2:
        x = np.frombuffer(raw, '<i2').astype(np.float64) / 32768
    elif sw == 3:
        b = np.frombuffer(raw, np.uint8).reshape(-1, 3)
        x = ((b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16)) << 8 >> 8) / 8388608.0
    elif sw == 4:
        x = np.frombuffer(raw, '<i4').astype(np.float64) / 2147483648
    elif sw == 1:
        x = (np.frombuffer(raw, np.uint8).astype(np.float64) - 128) / 128
    else:
        raise ValueError(sw)
    return x.reshape(-1, ch), sr

def writewav(p, x, sr=R):
    x = np.asarray(x, dtype=np.float64)
    pk = np.max(np.abs(x)) if len(x) else 0
    if pk > 0.999:
        x = x * (0.999 / pk)
    pcm = np.round(x * 32767).astype('<i2')
    w = wave.open(p, 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr); w.writeframes(pcm.tobytes()); w.close()

def asset(name):
    a = _assets.get(name)
    if a is not None:
        return a
    p = os.path.join(ASSET_DIR, name + '.wav')
    if not os.path.exists(p):
        p = os.path.join(ASSET_DIR, 'extra', name + '.wav')  # Full-profile sounds
    x, sr = readwav(p)
    x = x[:, 0]
    g = NOISE_FILE_GAIN.get(name, 1.0)
    m = re.match(r'bundle_g(\d)_(\d+)$', name)
    if m:
        g = BUNDLE_GAIN.get(int(m.group(1)) * 100 + BBASE[int(m.group(2))], 1.0)
    x = x * g
    # pad for cubic interpolation across the loop seam
    xp = np.concatenate([x[-1:], x, x[:3]])
    a = (xp, len(x), sr)
    _assets[name] = a
    return a

def read_cubic(name, pos_sec):
    xp, L, sr = asset(name)
    t = (pos_sec * sr) % L
    i = np.floor(t).astype(np.int64)
    f = t - i
    i = i + 1
    y0, y1, y2, y3 = xp[i - 1], xp[i], xp[i + 1], xp[i + 2]
    return y1 + 0.5 * f * (y2 - y0 + f * (2 * y0 - 5 * y1 + 4 * y2 - y3 + f * (3 * (y1 - y2) + y3 - y0)))

def parse(path):
    ev = {}
    marks = []
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0].isdigit() and len(p) >= 4:
            pid, b, code = int(p[0]), int(p[1]), p[2]
            v = p[3] if code == 'A' else float(p[3])
            ev.setdefault(pid, []).append((b, code, v))
        else:
            marks.append(p)
    return ev, marks

def render(ev, nblocks, ramp=64, only=None, stats=None):
    """ev: {pid: [(block, code, value)]} -> mono float array of nblocks * BLK samples.
    only: optional predicate(asset name) to render a subset. stats: dict filled with per-block active player counts."""
    out = np.zeros(nblocks * BLK)
    n = np.arange(BLK)
    rampw = np.clip((n + 1) / ramp, 0, 1) if ramp > 0 else np.ones(BLK)
    active = np.zeros(nblocks, int)
    for pid, lst in ev.items():
        lst = sorted(lst, key=lambda e: e[0])  # stable: keeps event order within a block
        name, playing, speed, vol, pos = None, False, 1.0, 1.0, 0.0
        cur_vol = 1.0
        j = 0
        for b in range(nblocks):
            # writes made during block b-1 land on this boundary
            while j < len(lst) and lst[j][0] <= b - 1:
                _, code, v = lst[j]
                if code == 'A':
                    name = v
                elif code == 'S':
                    speed = v
                elif code == 'V':
                    vol = v
                elif code == 'T':
                    pos = v
                elif code == 'P':
                    playing = v > 0.5
                j += 1
            if not playing:
                cur_vol = 0.0  # a player that (re)starts fades in from silence over the de-click ramp
                continue
            if name is not None and (vol > 0 or cur_vol > 0) and (only is None or only(name)):
                env = cur_vol + (vol - cur_vol) * rampw
                y = read_cubic(name, pos + speed * n / R)
                out[b * BLK:(b + 1) * BLK] += y * env
                if max(vol, cur_vol) > 1e-4:
                    active[b] += 1
            cur_vol = vol
            pos += speed * BLK / R
            if name is not None:
                L = asset(name)[1] / asset(name)[2]
                pos %= L
    if stats is not None:
        stats['active'] = active
    return out
