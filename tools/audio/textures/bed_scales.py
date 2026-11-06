import numpy as np, tex, sys
import os
S = os.path.dirname(os.path.abspath(__file__))
tex.set_shapes(tex.DEFAULT_SHAPES); tex.init_sources(); tex.init_sources2()
R = 48000; LOOP = 1.0
def stream_loop(k, seed):
    b = tex.BANDS2[k]; G = tex.g2(b['c']); g = int(G * R); hop = G / 2; w = np.sin(np.pi * (np.arange(g) + 0.5) / g)
    src = tex.SRC2[k]; rng = np.random.default_rng(seed)
    m = int(LOOP * R); y = np.zeros(m + g); i = 0
    while i * hop * R < m:
        o = rng.integers(0, len(src) - g); a = int(round(i * hop * R)); y[a:a + g] += src[o:o + g] * w; i += 1
    y[:g] += y[m:m + g]
    return y[:m]
def block_vol(vols, k, nb):
    b = tex.BANDS2[k]; G = tex.g2(b['c']); hop = G / 2; v = np.array(vols[k], float)
    t = np.arange(len(v)) * hop + G / 2
    bi = np.minimum((t / (1024 / R)).astype(int), nb - 1)
    out = np.zeros(nb); cnt = np.zeros(nb)
    np.add.at(out, bi, v ** 2); np.add.at(cnt, bi, 1)
    have = cnt > 0; p = np.zeros(nb); p[have] = out[have] / cnt[have]
    idx = np.arange(nb)
    p = np.interp(idx, idx[have], p[have]) if have.any() else p
    return np.sqrt(p)
loops = [stream_loop(k, 300 + k) for k in range(len(tex.BANDS2))]
res = {}
for nm in sys.argv[1:]:
    x = np.load(S + '/tx/x_%s.npy' % nm); n = len(x); nb = (n + 1023) // 1024
    enc = tex.encode2(x); vols = enc['grains']
    sc = []
    for k in range(len(tex.BANDS2)):
        seg = np.resize(np.roll(loops[k], -((k * 7919) % R)), nb * 1024)
        yk = (seg * np.repeat(block_vol(vols, k, nb), 1024))[:n]
        vv = [np.zeros(len(v)) for v in vols]; vv[k] = np.array(vols[k], float)
        want = np.sum(tex.grains_wave2(vv, n) ** 2); got = np.sum(yk ** 2)
        sc.append(np.sqrt(want / got) if got > 1e-12 and want > 1e-12 else np.nan)
    res[nm] = np.array(sc)
    print(nm, ' '.join('%.2f' % v for v in sc), flush=True)
sys.argv[1:] and np.save('bed_scales.npy', np.array([res[k] for k in sys.argv[1:]]))
