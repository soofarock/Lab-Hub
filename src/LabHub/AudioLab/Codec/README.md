# AudioLab / Codec

The generic sounds AudioLab plays everything with, and the clip formats that describe a sound in terms of them.

| Module | What it does |
| --- | --- |
| `WaveBank` | The fixed set of uploaded loops (waveforms, harmonic bundles, noise bands, decaying sines) and the exact math that defines them. Changing it means remaking and re-uploading the assets. |
| [`Manifests/`](Manifests) | Which uploaded files are used, by name, for each profile (`Lean`, `Full`), and their asset ids. |
| `Analyzer` | FFT analysis: PCM into control frames for the waveform synth. |
| `Format` | The `RBAC` clip format (waveform voices + noise bands). |
| `Partials` | The `RBA3` clip format for recordings: tracked sine partials + noise bands. |
| `Texture` | The `RBA4` clip format for short sound effects: tones, clicks and noise beds started at exact times. `Texture.LAYOUT` says which upload file holds each piece. |
| `Encoder` | The entry point: an audio file or `Signal` in, a packed clip out. |
