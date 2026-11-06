# Assets / audio

AudioLab's generic sounds. Nothing here is a song or a recording: every file is a waveform, a noise band or a texture piece that AudioLab combines in game.

This folder holds the **72 core** files. They are public on Roblox, the release plays them, and they are all the `Lean` profile (the default) needs. [`extra/`](extra) holds the rest.

| Files | What they are |
| --- | --- |
| `wave_<shape>_<base>` | One-second seamless loops: sine (880 Hz only, played at every pitch), triangle, saw, square, pulse 25 % and 12.5 %, at 55, 220, 880 and 3520 Hz. |
| `bundle_g1..g3_<base>` | Harmonic bundles: one player carries an octave of harmonics. |
| `noise_4_1000`, `noise_6_4000` | Octave noise bands; played at different speeds they make all 16 bands. |
| `pink_noise` | Pink noise: the breath and air of voices. |
| `rough_880` | Narrow noise around 880 Hz: the roughness a steady sine lacks. |
| `tex_tones_01..15` | Texture tones: 120 gliding and decaying tone shapes. |
| `tex_clicks_01`, `tex_clicks_low_*` | Texture clicks: decaying noise bursts. |
| `tex_beds_01..13` | Texture beds: one-second noise-band loops, 4 per file. |
| `tex_loop` | A 1 kHz noise loop for the texture player's low-cost mode. |

[`manifest.csv`](manifest.csv) lists every sound (core and extra): name, asset id (empty for the extra sounds), profiles, set, file and length. All files are mono, 16-bit, 44.1 or 48 kHz, and 4.16 s or shorter.

`tools/audio/README.md` says which script makes each file.
