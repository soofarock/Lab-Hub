# AudioLab

Rebuilds music and sounds in-game from a small set of generic uploaded waveforms, played by AudioPlayers. MIDI + SoundFont songs are synthesised live. WAV, AIFF, MP3, AAC, OGG and FLAC sounds are encoded into small clips and played back by the same synth.

`init.luau` is the `AudioLab` module: `AudioLab.init()`, `AudioLab.play(...)` and the other track calls, and lazy access to the modules below (`AudioLab.Wav`, `AudioLab.MidiSynth`, ...). Its attributes are AudioLab's settings, for example `Manifest` (`Lean` or `Full`) and `Debug`.

| Folder / module | What it holds |
| --- | --- |
| [`Util/`](Util) | Binary readers and writers, Base64. |
| [`Formats/`](Formats) | Decoders for the audio file formats, MIDI and SoundFont 2. |
| [`DSP/`](DSP) | The PCM container and the FFT. |
| [`Codec/`](Codec) | The generic waveform set, the analysers and the clip formats. |
| [`Synth/`](Synth) | The players: voice pool, MIDI synth, clip players, track manager. |
| [`Tools/`](Tools) | Import into the place, decode cache, SoundFont baking, track library. |
| [`Data/`](Data) | Imported files, baked banks and encoded clips, stored in the place. |
| [`Runtime/`](Runtime) | What runs in a game: the sync server, the Studio import server, the client players and the music player. |
| `Sync.luau` | Server-authoritative playback: the server writes a few attributes on an instance and every client plays it on the server's playhead. |
