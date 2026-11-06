# Render chain for a clip's events: render -> crackle noise above 1.4 kHz -> hit layer (exact-time bursts, smeared
# hit energy taken out of the continuous layer).
import numpy as np, render as RN, crackle as CK, hits as H
R = 48000
_made = False
def assets():
    global _made
    if _made: return
    for nm, (src, rate) in {'crk_1k': ('noise_4_1000', 300), 'crk_4k': ('noise_6_4000', 1500)}.items():
        y = CK.make(src, rate); RN._assets[nm] = (np.concatenate([y[-1:], y, y[:3]]), len(y), R)
    _made = True
def chain(path, rf, crackle=True, hits=True):
    assets()
    ev, marks = RN.parse(path)
    if crackle:
        for pid, l in ev.items():
            nmz = [v for b, c, v in l if c == 'A']; sp = [v for b, c, v in l if c == 'S']
            if nmz and nmz[-1] == 'noise_6_4000': ev[pid] = [(b, c, 'crk_4k' if c == 'A' else v) for b, c, v in l]
            elif nmz and nmz[-1] == 'noise_4_1000' and sp and np.median(sp) * 1000 >= 1400: ev[pid] = [(b, c, 'crk_1k' if c == 'A' else v) for b, c, v in l]
    i = [q for q, m in enumerate(marks) if m[0] == 'R'][0]; Cm = [m for m in marks[i:] if m[0] == 'C'][0]
    B, t = int(Cm[1]), float(Cm[2]); end = int([m for m in marks if m[0] == 'END'][0][1])
    n = len(rf); a = int(round((B + 1) * 1024 - (t - 0.5 * 1024 / R) * R)) - 2400
    y = RN.render(ev, end); y = np.concatenate([y[a:a + n], np.zeros(max(0, n - len(y[a:a + n])))])[:n]
    if hits:
        k = int(0.0025 * R); sm = lambda z: np.convolve(z ** 2, np.ones(k) / k, 'same') + 1e-12
        g = np.minimum(1, np.sqrt(sm(rf) / sm(y))); g = np.convolve(g, np.ones(k // 2) / (k // 2), 'same')
        y, _ = H.add_hits(rf, y * g)
    return y
def score(rf, y):
    e_o, _ = H.env(rf, 5); e_z, _ = H.env(y, 5); m = e_o > e_o.max() - 40
    import metrics as M
    mm = M.compare(rf, y, f0=None, level_match=False)
    return dict(err=mm['spec_err'], lvl=mm['level_db'], env5=np.mean(np.abs(e_o - e_z)[m]), hits=(int(np.sum(np.diff(e_o) > 10)), int(np.sum(np.diff(e_z) > 10))))
