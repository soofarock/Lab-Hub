# The click upload files (Texture.SplitSeconds.clicks = 2.0, Texture.ClickRemap = "low"):
#   tex_clicks_01       the first 15 clicks (500 Hz, and 1000 Hz with the two short decays), at their own band
#   tex_clicks_low_NN   higher clicks made in the 500 Hz band with a k times longer decay (k = band / 500); the game
#                       plays them k times faster, which puts each back in its own octave band with its own decay
#                       (volume x sqrt(k) keeps the energy). Texture.ClickLow lists where each one sits.
# Clicks with no file of their own play another click sped up (Texture: "reuse").
# Run it from the folder that should get the files.
import numpy as np, os, sys
sys.argv = ['x']
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tex, render as RN

R = 48000
SC = 1 / 0.4205890097923391   # the clicks' common scale (Texture GAIN.clicks)
LS = int(0.1 * R)             # silence before every click
KEEP_MAX = 2.0 * R            # tex_clicks_01: the first file of the 2.0 s packing
USED = {'tex_clicks_01', 'tex_clicks_low_03', 'tex_clicks_low_07', 'tex_clicks_low_08', 'tex_clicks_low_09',
        'tex_clicks_low_10'}  # the files the game has ids for

keys = [(b, t, v) for b in range(len(tex.CB)) for t in range(len(tex.TAUS)) for v in range(3)]
table = {}  # click index (1-based, as Texture) -> (file, start sample)

def write(name, items, indices=()):
    x = np.zeros(max(p + len(y) for p, y in items) + LS)
    for p, y in items:
        x[p:p + len(y)] = y
    assert np.abs(x).max() <= 0.999, name  # (writewav would rescale: the game's gains would no longer match)
    if name in USED:
        RN.writewav(name + '.wav', x)
        for i, (p, _) in zip(indices, items):
            table[i] = (name, p)
        print('-- %s.wav  %d clicks  %.2f s' % (name, len(items), len(x) / R))

def low(i, seed):
    b, t, v = keys[i - 1]
    kf = tex.CB[b] / tex.CB[0]
    return tex.burst(tex.CB[0], tex.TAUS[t] * kf, v + seed) * SC

def pack(indices, seed, max_s, first_num):
    """clicks in order, each after LS of silence, a new file when one would pass max_s; files numbered from first_num"""
    cur, idx, pos, num = [], [], 0, first_num
    for i in indices:
        y = low(i, seed)
        if cur and pos + LS + len(y) + LS > max_s * R:
            write('tex_clicks_low_%02d' % num, cur, idx); cur, idx, pos = [], [], 0; num += 1
        pos += LS; cur.append((pos, y)); idx.append(i); pos += len(y)
    write('tex_clicks_low_%02d' % num, cur, idx)

# tex_clicks_01: the clicks that fit in the first 2.0 s file
keep, pos = [], 0
for k in keys:
    n = int(tex.TAUS[k[1]] * 7 * R) + 64
    if pos > 0 and pos + LS + n + LS > KEEP_MAX:
        break
    pos += LS; keep.append((pos, tex.burst(tex.CB[k[0]], tex.TAUS[k[1]], k[2]) * SC)); pos += n
write('tex_clicks_01', keep)
first, last = len(keep) + 1, len(keys)

pack([last], 0, 4.16, 3)               # tex_clicks_low_03: click 45 (seed v)
pack(range(first, last), 100, 1.5, 4)  # clicks from 16 (seed v + 100), files of 1.5 s from low_04: 07..10 hold 35..44

print('Texture.ClickLow = {')
for i in sorted(table):
    print('\t[%d] = { "%s", %d },' % (i, table[i][0], table[i][1]))
print('}')
