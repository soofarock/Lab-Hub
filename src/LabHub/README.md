# LabHub (package root)

`init.luau` is the `LabHub` ModuleScript itself: the Labs menu (`LabHub.add`, `LabHub.closeAll`), `LabHub.start()`, and lazy access to the parts below (`LabHub.FrameLab`, `LabHub.AudioLab`, ...).

| Item | What it is |
| --- | --- |
| [`FrameLab/`](FrameLab) | Pictures and video drawn with GUI objects; TVs, sprays, the data manager and the settings panel. |
| [`AudioLab/`](AudioLab) | Audio formats and the synth that rebuilds music and sounds from generic uploaded waveforms. |
| `VideoLab.luau` | Video with sound from one file: FrameLab's picture and AudioLab's sound on one clock. |
| `Config.luau` | Every setting, its default and what it does. The live values are attributes on `LabHub.FrameLab`. |
| `Instancer.luau` | Builds instances from plain Luau descriptions. |
| `Blueprints.luau` | The descriptions Instancer builds: the TV and Spray Paint tools, and the TV model. |
| `DevKit.luau` | Studio command-bar helpers: list the bundled media with sizes, remove items, run the shipping check. |

## Starting it

One line on each side, from a Script in ServerScriptService and a LocalScript in StarterPlayerScripts:

```lua
require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub")).start()
```

`start()` runs `AudioLab.init()` and `FrameLab.init()` once on that side. Each of those starts every module in its `Runtime/Server` or `Runtime/Client` folder.
