# Assets / audio / extra

The 83 sounds outside the core set. They have no public upload: to use them, upload the ones you want and add their ids (`assets/audio/manifest.csv`, then `lune run tools/set_audio_ids`). The `Full` profile uses every one that has an id, except `tex_grains2`; `tools/audio/make_atlas.py --set full` packs them into an atlas instead.

| Files | What they are |
| --- | --- |
| `wave_sine_55`, `_220`, `_3520` | The other sine bases. |
| `bundle_g4_<base>` | The fourth harmonic-bundle group. |
| `noise_<n>_<centre>` | The rest of the 16 noise bands, each as its own file. |
| `dsine_<base>_t1..t11` | Decaying sines at 11 decay times: note fades. |
| `burst_<band>_t6/t25` | Sharp-onset noise bursts. |
| `pulse_g2..g5_<base>` | Pulse bundles. |
| `tex_grains2` | Texture grains: what texture clips play when the bed files can't load. |
