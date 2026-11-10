# AudioLab / Formats

Every decoder takes the file's bytes and returns PCM in a `DSP.Signal` (or, for MIDI and SoundFont, the parsed data).

| Module | Format |
| --- | --- |
| `Wav` | WAV (RIFF/WAVE): decode and encode. |
| `Aiff` | AIFF / AIFF-C: decode and encode. |
| `Mp3` | MPEG-1 / 2 / 2.5 audio: Layer III (MP3) and Layers I and II (MP2). |
| `Aac` | AAC-LC (MPEG-4), raw ADTS or inside MP4 / M4A. |
| `Ogg` | Ogg Vorbis (Ogg Opus goes to `Opus`). |
| `Opus` | Opus (SILK, CELT and hybrid, with packet loss concealment), in Ogg or inside MP4 / MOV. A port of libopus's decoder; its BSD license notice is in the module. |
| `Flac` | FLAC. |
| `Ac3` | AC-3 (Dolby Digital): every channel mode; surround is mixed down to stereo. |
| `Midi` | Standard MIDI files: events, tempo map, note pairing. |
| `Sf2` | SoundFont 2: presets, instruments, zones and samples. |
| `Iff` | The chunk walker WAV, AIFF and SF2 share. |
