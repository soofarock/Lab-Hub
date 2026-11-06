# AudioLab / Codec / Manifests

`init.luau` is `Manifests`: the profiles and which sounds each one uses. The profile is the AudioLab attribute `Manifest`.

| Profile | Uses |
| --- | --- |
| `Lean` (default) | The 72 public files: one sine for every pitch, the other waveforms at four bases, harmonic bundles, two noise files for all 16 noise bands, pink noise, the rough sine and the texture files. |
| `Full` | Every file in `Files`: the Lean files plus any extra sounds you upload and list there (other sine bases, the other noise bands, onset bursts, pulses, decaying sines). |
| `Atlas` | The sounds of your atlas packs in `Atlas`. With no uploaded pack it plays as Lean. |

| Module | What it holds |
| --- | --- |
| `Files` | Sound name → asset id, one uploaded file per sound. To add or change ids, see `tools/set_audio_ids.luau`. |
| `Atlas` | Your atlas packs: sounds stored as regions of a few larger files, played with `LoopRegion`. `tools/audio/make_atlas.py` makes the files and their entries. |

Every profile also plays the texture files, `rough_880` and `pink_noise` as their own files (`Manifests.Core`).

When a server starts, `Runtime/Server/PreloadSetup` builds `ReplicatedFirst.AudioLabPreload` from these lists, so joining players start loading the files right away.
