# The texture codec's tone and loop upload files (the clicks: make_clicks_split.py; the grains: `mkassets.py grains2`).
# Pieces are packed: each after a stretch of silence (lead-in), so the player can start one at an exact time by setting
# TimePosition a little before it. Run it from the folder that should get the files; it also writes layout.json.
#   tex_tones_01 .. tex_tones_15   120 tone shapes, files of at most 4.16 s (Texture.SplitSeconds.tones)
#   tex_loop                       the clean 1 kHz half-octave noise (low-cost mode)
import numpy as np, tex, render as RN, json, os
R = 48000
OUT = os.getcwd()
os.makedirs(OUT, exist_ok=True)
LEAD = dict(tones=0.40, clicks=0.10, grains=0.08)
PEAK = 0.9
SPLIT = dict(tones=4.16)  # kind -> seconds per upload file (the same packing as Texture.SplitSeconds)
def pack(items, lead, max_s=1e9):
    """items in order, each after `lead` s of silence; a new file starts when an item (and the `lead` of silence that ends
    every file) would take the file past max_s. Returns the files and, per item, (file index from 1, start in that file, s)."""
    L, MAXS = int(lead * R), int(max_s * R)
    files, where, cur, pos = [], [], [], 0
    for y in items:
        if pos > 0 and pos + L + len(y) + L > MAXS:
            cur.append(np.zeros(L)); files.append(np.concatenate(cur)); cur, pos = [], 0
        cur.append(np.zeros(L)); pos += L
        where.append((len(files) + 1, pos / R)); cur.append(y); pos += len(y)
    cur.append(np.zeros(L)); files.append(np.concatenate(cur))
    return files, where
def build():
    tex.set_shapes(tex.DEFAULT_SHAPES); tex.init_sources()
    lay = {}
    # tones: peak-normalised shapes
    ys = [s['y'] * PEAK for s in tex.FAM]
    fl, wh = pack(ys, LEAD['tones'], SPLIT['tones'])
    names = ['tex_tones_%02d' % (i + 1) for i in range(len(fl))]
    for nm, w in zip(names, fl):
        RN.writewav(OUT + '/%s.wav' % nm, w)
    lay['tones'] = dict(lead=LEAD['tones'], where=wh, files=names, len=[len(y) / R for y in ys], gain=1 / PEAK)
    # loop (low-cost mode: bands under 1 kHz as steady loops): the clean 1 kHz half-octave noise the low grains are cut from
    import grain as G
    src = G.file_for(250)[0]['src']; s = PEAK / np.abs(src).max()
    RN.writewav(OUT + '/tex_loop.wav', src * s)
    lay['loop'] = dict(gain=1 / s, len=len(src) / R, centre=1000.0, files=['tex_loop'])
    print('tones', len(names), 'files', ' '.join('%.2f' % (len(w) / R) for w in fl))
    json.dump(lay, open(OUT + '/layout.json', 'w'))
    return lay
if __name__ == '__main__' and len(__import__('sys').argv) == 1:
    build()

K2 = 12
def build_grains2():
    """the grain file (tex_grains2, the fallback for when the tex_beds files can't load): K2 sine-windowed puffs per band of tex.BANDS2, each after LEAD['grains'] of silence"""
    tex.set_shapes(tex.DEFAULT_SHAPES); tex.init_sources(); tex.init_sources2()
    items, gains = [], []
    for k, b in enumerate(tex.BANDS2):
        g = int(tex.g2(b['c']) * R); win = np.sin(np.pi * (np.arange(g) + 0.5) / g)
        src = tex.SRC2[k]; rng = np.random.default_rng(500 + k)
        puffs = [src[o:o + g] * win for o in rng.integers(0, len(src) - g, K2)]
        # the set as a whole carries the source's power (a few random puffs of narrow noise can be off by several dB)
        fix = np.sqrt(0.5 * np.mean(src ** 2) / np.mean([np.mean(p ** 2) for p in puffs]))
        puffs = [p * fix for p in puffs]
        s = PEAK / max(np.abs(p).max() for p in puffs); gains.append(1 / s)
        items += [p * s for p in puffs]
    fl, wh = pack(items, LEAD['grains'])
    RN.writewav(OUT + '/tex_grains2.wav', fl[0])
    lay = json.load(open(OUT + '/layout.json')) if os.path.exists(OUT + '/layout.json') else {}
    lay['grains2'] = dict(lead=LEAD['grains'], K=K2, gain=gains, g=[tex.g2(b['c']) for b in tex.BANDS2], unit=tex.UNIT2,
                          w=[b['w'] for b in tex.BANDS2], c=[b['c'] for b in tex.BANDS2],
                          where=[wh[i * K2:(i + 1) * K2] for i in range(len(tex.BANDS2))])
    json.dump(lay, open(OUT + '/layout.json', 'w'))
    print('tex_grains2: %.1f s, %d puffs, max gain %.2f' % (len(fl[0]) / R, len(items), max(gains)))
if __name__ == '__main__' and len(__import__('sys').argv) > 1 and __import__('sys').argv[1] == 'grains2':
    build_grains2()
