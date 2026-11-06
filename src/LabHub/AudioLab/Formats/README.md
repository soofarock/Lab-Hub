# AudioLab / Formats

Every decoder takes the file's bytes and returns PCM in a `DSP.Signal` (or, for MIDI and SoundFont, the parsed data).

| Module | Format |
| --- | --- |
| `Wav` | WAV (RIFF/WAVE): decode and encode. |
| `Aiff` | AIFF / AIFF-C: decode and encode. |
| `Mp3` | MPEG-1/2 Layer III. |
| `Aac` | AAC-LC (MPEG-4), raw ADTS or inside MP4 / M4A. |
| `Ogg` | Ogg Vorbis. |
| `Flac` | FLAC. |
| `Midi` | Standard MIDI files: events, tempo map, note pairing. |
| `Sf2` | SoundFont 2: presets, instruments, zones and samples. |
| `Iff` | The chunk walker WAV, AIFF and SF2 share. |
