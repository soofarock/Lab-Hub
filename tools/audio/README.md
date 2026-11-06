# Audio asset tools

These scripts make AudioLab's generic sounds, the 155 WAVs listed in `assets/audio/manifest.csv` (with their asset ids, where they have a public upload):

- **core**: the 72 in `assets/audio`, public on Roblox. They are all the `Lean` profile (the default) needs.
- **extra**: the 83 in `assets/audio/extra`, used by the `Full` profile once you upload them, plus `tex_grains2`, which textures fall back to when the bed files can't load.

Each script writes into the **current folder**, so run it from where you want the files:

```
mkdir build && cd build
python ../tools/audio/make_waves_noise.py
```

Requirements: Python 3 with numpy. The texture scripts also need SciPy.

| Script | Makes | Same samples as the files in `assets/audio`? |
| --- | --- | --- |
| `make_waves_noise.py` | `wave_<sine/triangle/saw/square/pulse25/pulse12>_<55/220/880/3520>` (exactly 1 s, seamless loops) and `noise_1_125` … `noise_8_16000` (octave noise bands). Core: the 21 waves the Lean profile uses, `noise_4_1000`, `noise_6_4000`. | yes |
| `make_bundles_noise2.py` | `bundle_g1..g4_<base>` (one player carries an octave of harmonics) and `noise_9_88` … `noise_16_11314` (half-octave offset bands). Core: `bundle_g1`–`g3`. | yes |
| `make_pink.py` (core) | `pink_noise` (3 s seamless loop) | yes |
| `make_rough.py` (core) | `rough_880` (noise centred on 880 Hz, 3 % wide: the "rough sine") | yes |
| `make_bursts_pulses.py` (extra) | `burst_<band>_t6/t25` (sharp-onset noise bursts), `pulse_g2..g5_<base>` | yes |
| `make_decay_sines.py` (extra) | `dsine_<55/220/880/3520>_t1..t11` (decaying sines, 11 decay times; files end at 4.16 s at most) | `t1`–`t7`: yes. `t8`–`t11`: the files in `assets/audio/extra` run longer (4.7–19 s); the game plays only their first 4.16 s, which is what the script writes. |
| `textures/mkassets.py` (core) | `tex_tones_01` … `tex_tones_15` (120 tone shapes, files of at most 4.16 s), `tex_loop` | `tex_tones_*`: yes. `tex_loop`: no. The script writes a 1.37 s loop of the same 1 kHz band; the game's gain is set for the 3 s file in `assets/audio`. |
| `textures/make_clicks_split.py` (core) | `tex_clicks_01` (the 500 Hz and short 1000 Hz clicks) and `tex_clicks_low_03`, `_07` … `_10` (higher clicks made in the 500 Hz band, played faster). It prints the `Texture.ClickLow` table. | yes |
| `textures/mk_beds13.py` (core) | `tex_beds_01` … `tex_beds_13` (texture beds: band loops, 4 per file) | `05`–`13`: yes. `01`–`04`: no. |
| `textures/mkassets.py grains2` (extra) | `tex_grains2` (the grain fallback) | no |
| `make_atlas.py` | Your own atlas: the WaveBank sounds of `assets/audio` (`--set lean`) or of both folders (`--set full`) packed into WAVs, plus the Luau entries for `Codec/Manifests/Atlas`. See "Your own atlas" in the main README. | (packs the files here) |

Where a file can't be remade sample for sample, the one in `assets/audio` is the reference: the game's levels match it.

`textures/` also holds the texture codec's analysis modules, which the entry points above import. They read the generic sounds from `assets/audio` and `assets/audio/extra`.

## Upload limits these files keep to

- Mono, 16-bit, 44.1 or 48 kHz.
- Every core file is 4.16 s or shorter. In extra, the files of `dsine_*_t8`–`t11` (4.7–19 s) and `tex_grains2` (68 s) are longer. All are well under Roblox's 7-minute / 20 MB limit.
- Loops are a whole number of cycles, or a circular spectrum, so they repeat with no click.

To use your own uploads, follow the steps under "Uploaded assets" in the main README: put the ids in `manifest.csv`, then run `lune run tools/set_audio_ids`.
