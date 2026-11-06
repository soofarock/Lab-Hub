# AudioLab / Synth

| Module | What it does |
| --- | --- |
| `OscillatorPool` | The voice pool: looping WaveBank AudioPlayers driven by PlaybackSpeed (pitch) and Volume, reused instead of created and destroyed. |
| `MidiSynth` | Real-time MIDI sequencer and synthesiser on the voice pool. |
| `Instruments` | Instrument presets: General MIDI programs, the drum kit, and SoundFont analysis into voices. |
| `Player` | Plays `RBAC` and `RBA3` clips through a voice pool. |
| `TexturePlayer` | Plays `RBA4` texture clips: each piece is one start of a generic file at an exact time. |
| `Tracks` | The track manager behind `AudioLab.play`: pause, resume, stop, fades, crossfades and playlists. |
| `Attach` | Audio attached to instances (3D output through an AudioEmitter), with a registry any script can query. |
| `Renderer` | Renders a clip to PCM / WAV outside the engine, with the same waveform definitions. |
