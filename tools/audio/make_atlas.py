"""Export your own AudioLab atlas: the generic sounds packed into one (or a few) WAV files that you upload yourself,
plus the Luau that tells AudioLab where each sound sits.

    python tools/audio/make_atlas.py                        -> atlas.wav + atlas.luau   (the Lean sounds)
    python tools/audio/make_atlas.py --set full             -> every sound in assets/audio and assets/audio/extra
    python tools/audio/make_atlas.py --name mine --max-seconds 60   -> mine_01.wav, mine_02.wav ... + mine.luau

Then:
  1. Upload each WAV (Creator Hub > Audio).
  2. Paste the .luau into LabHub > AudioLab > Codec > Manifests > Atlas, below `local Atlas = {...}`, and put each
     file's asset id in its pack's `id`.
  3. Set the AudioLab attribute Manifest = "Atlas" (or pick Atlas in Labs > Settings).

The texture files, rough_880 and pink_noise are not packed: every profile plays them as their own files
(Codec.Manifests.Core).

Layout of a pack (Codec/Manifests/Atlas): 1 unit = 375 samples = 1/128 s at 48 kHz, so every boundary is sample-exact.
A loop is [pre: silence][onset: 1 unit, the loop's last unit fading in][body: the loop, L units][2 units fading out];
the loop region is the body. A one-shot is [pre: silence][the sound, rounded up to whole units]. A player started
inside the silence before the onset begins its sound that much later, which is how a note can start mid audio block.

Every sound is resampled to 48 kHz (a loop around its own cycle, so it stays seamless) and keeps its level: the
game's per-sound gains still apply.

Needs: Python 3 with numpy (and SciPy for sounds that are not 48 kHz one-shots).
"""
import argparse, math, os, struct, sys, wave
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
AUDIO = os.path.join(ROOT, "assets", "audio")
RATE, UNIT, POST, RAMP = 48000, 375, 2, 48

def lean(name):
    """the Lean profile's sounds (Codec.Manifests: leanSet)"""
    if name.startswith("wave_"):
        return name not in ("wave_sine_55", "wave_sine_220", "wave_sine_3520")
    if name.startswith("bundle_"):
        return name not in ("bundle_g4_110", "bundle_g4_220")
    if name.startswith("noise_"):
        return name in ("noise_4_1000", "noise_6_4000")
    return False

PACKED = ("wave_", "bundle_", "noise_", "pulse_", "burst_", "dsine_")  # WaveBank's sounds
ONE_SHOT = ("burst_", "dsine_")

def kind_order(name):
    for i, p in enumerate(PACKED):
        if name.startswith(p):
            return i
    return len(PACKED)

def read_wav(path):
    with wave.open(path) as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2, path + ": mono 16-bit expected"
        rate, n = w.getframerate(), w.getnframes()
        x = np.frombuffer(w.readframes(n), "<i2").astype(np.float64) / 32768
    return x, rate

def loop_to(x, m):
    """a seamless loop resampled to m samples around its own cycle (band-limited, exact for periodic signals)"""
    if len(x) == m:
        return x.copy()
    X = np.fft.rfft(x)
    Y = np.zeros(m // 2 + 1, dtype=complex)
    k = min(len(X), len(Y))
    Y[:k] = X[:k]
    if m % 2 == 0 and k == len(Y):
        Y[-1] = Y[-1].real  # the Nyquist bin of an even length is real
    return np.fft.irfft(Y, m) * (m / len(x))

def one_shot_to_48k(x, rate):
    if rate == RATE:
        return x.copy()
    from scipy.signal import resample_poly
    g = math.gcd(RATE, rate)
    return resample_poly(x, RATE // g, rate // g)

def segment(name, x, rate):
    """(samples of the whole segment, pre, length in units, one-shot?) for one sound"""
    pre = 64 if name == "wave_sine_880" else (4 if name.startswith(("bundle_", "pulse_")) else 6)
    if name.startswith(ONE_SHOT):
        y = one_shot_to_48k(x, rate)
        L = max(1, math.ceil(len(y) / UNIT))
        body = np.zeros(L * UNIT)
        body[:len(y)] = y
        return np.concatenate([np.zeros(pre * UNIT), body]), pre, L, True
    L = max(1, round(len(x) / rate * RATE / UNIT))
    loop = loop_to(x, L * UNIT)
    onset = loop[-UNIT:].copy()
    r = np.arange(RAMP)
    onset[:RAMP] *= 0.5 - 0.5 * np.cos(np.pi * (r + 0.5) / RAMP)
    tail = np.resize(loop, POST * UNIT)
    m = POST * UNIT
    tail *= 0.5 + 0.5 * np.cos(np.pi * (np.arange(m) + 0.5) / m)
    return np.concatenate([np.zeros(pre * UNIT), onset, loop, tail]), pre, L, False

def write_wav(path, y):
    pcm = np.clip(np.round(y * 32767), -32768, 32767).astype("<i2").tobytes()
    with open(path, "wb") as fh:
        fh.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE")
        fh.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16))
        fh.write(b"data" + struct.pack("<I", len(pcm)) + pcm)
    return np.frombuffer(pcm, "<i2").astype(np.float64) / 32768

def main():
    ap = argparse.ArgumentParser(description="Pack AudioLab's generic sounds into atlas WAVs + their Luau pack entries.")
    ap.add_argument("--set", choices=("lean", "full"), default="lean", help="lean: the Lean profile's sounds; full: every packed sound")
    ap.add_argument("--name", default="atlas", help="pack name (a Luau identifier); files are <name>.wav or <name>_NN.wav")
    ap.add_argument("--max-seconds", type=float, default=0, help="split into files of at most this many seconds (0: one file)")
    ap.add_argument("--out", default=".", help="folder for the WAVs and the .luau")
    a = ap.parse_args()
    if not a.name.isidentifier():
        sys.exit("--name must be a Luau identifier (letters, digits, _)")

    found = {}
    for folder in (AUDIO, os.path.join(AUDIO, "extra")):
        for f in sorted(os.listdir(folder)):
            n = f[:-4]
            if f.endswith(".wav") and n.startswith(PACKED) and (a.set == "full" or lean(n)):
                found[n] = os.path.join(folder, f)
    names = sorted(found, key=lambda n: (kind_order(n), n))
    if not names:
        sys.exit("no sounds found in " + AUDIO)

    segs = []
    for n in names:
        x, rate = read_wav(found[n])
        segs.append((n,) + segment(n, x, rate))

    # packs: segments in order, a new file when one would pass --max-seconds (2 units of silence end every file)
    max_units = int(a.max_seconds * RATE / UNIT) if a.max_seconds > 0 else None
    packs, cur, units = [], [], 0
    for s in segs:
        u = len(s[1]) // UNIT
        if cur and max_units and units + u + POST > max_units:
            packs.append(cur)
            cur, units = [], 0
        cur.append(s)
        units += u
    packs.append(cur)
    os.makedirs(a.out, exist_ok=True)
    pack_names = [a.name] if len(packs) == 1 else ["%s_%02d" % (a.name, i + 1) for i in range(len(packs))]

    lua = ["-- AudioLab atlas: paste below `local Atlas = {...}` in LabHub > AudioLab > Codec > Manifests > Atlas, then put",
           "-- each uploaded file's asset id in its pack's `id` and set the AudioLab attribute Manifest = \"Atlas\".",
           "-- (made by tools/audio/make_atlas.py --set %s)" % a.set]
    worst = 0
    for pname, pack in zip(pack_names, packs):
        parts, pos, rows = [], 0, []
        for n, y, pre, L, shot in pack:
            onset = pos + pre
            if shot:
                rows.append("\t\t%s = { %d, %d, %d, %d, false }," % (n, pre, onset, onset, L))
            else:
                rows.append("\t\t%s = { %d, %d, %d, %d }," % (n, pre, onset, onset + 1, L))
            parts.append(y)
            pos += len(y) // UNIT
        parts.append(np.zeros(POST * UNIT))
        pos += POST
        y = np.concatenate(parts)
        assert len(y) == pos * UNIT
        peak = np.abs(y).max()
        if peak >= 1:
            sys.exit("%s: peak %.3f would clip" % (pname, peak))
        q = write_wav(os.path.join(a.out, pname + ".wav"), y)
        # seam check: around the loop end the file must hold what it holds around the loop start (the same cycle)
        p = 0
        for n, seg, pre, L, shot in pack:
            if not shot:
                B = (p + pre + 1) * UNIT
                E = B + L * UNIT
                worst = max(worst, np.abs(q[E - 8:E] - q[B - 8:B]).max())
            p += len(seg) // UNIT
        lua += ["", "Atlas.packs.%s = {" % pname,
                "\tid = \"\", -- %s.wav: put its asset id here (\"rbxassetid://...\")" % pname,
                "\trate = %d," % RATE, "\tunit = %d," % UNIT, "\tlength = %.4f," % (len(y) / RATE), "\tsegments = {"]
        lua += rows + ["\t},", "}", "table.insert(Atlas.order, \"%s\")" % pname]
        print("%s.wav: %d sounds, %.2f s, peak %.3f" % (pname, len(pack), len(y) / RATE, peak))
    with open(os.path.join(a.out, a.name + ".luau"), "w") as fh:
        fh.write("\n".join(lua) + "\n")
    print("%s.luau written; worst loop seam %.1f (16-bit steps)" % (a.name, worst * 32768))

if __name__ == "__main__":
    main()
