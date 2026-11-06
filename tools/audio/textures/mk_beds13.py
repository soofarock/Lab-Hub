# tex_beds as 13 files of 4 one-second band loops each (4.16 s; the last file holds 1): every band gets a 1 s loop of its
# noise (fixed seeds), played at speed 1. Each slot is stored reversed (noise sounds the same either way).
import numpy as np, tex, json, sys, os, zipfile
sys.argv = ['x']
import bed_scales
import scipy.io.wavfile as wf
R = 48000; PAD = 0.02; LOOP = 1.0; PER = 4
B = tex.BANDS2; NB = len(B)
out_dir = os.getcwd()  # run it from the folder that should get the files
bed_scales.LOOP = LOOP
layout = []; files = []
for f in range((NB + PER - 1) // PER):
    name = 'tex_beds_%02d' % (f + 1); files.append(name); parts = []; pos = 0.0
    for k in range(f * PER, min(NB, (f + 1) * PER)):
        lp_ = bed_scales.stream_loop(k, 300 + k); P = int(PAD * R)
        src = tex.SRC2[k]; lp_ = lp_ * np.sqrt(np.mean(src ** 2) / np.mean(lp_ ** 2))
        g = 0.9 / np.abs(lp_).max()
        slot = (np.concatenate([lp_[-P:], lp_, lp_[:P]]) * g)[::-1]
        layout.append(dict(file=f + 1, start=(pos * R + P) / R, len=len(lp_) / R, gain=float(g)))
        parts.append(slot); pos += len(slot) / R
    y = np.concatenate(parts)
    wf.write('%s/%s.wav' % (out_dir, name), R, np.round(np.clip(y, -1, 1) * 32767).astype(np.int16))
    print(name, '%.2f s' % (len(y) / R))
json.dump(dict(files=files, bands=layout), open(out_dir + '/layout.json', 'w'))
