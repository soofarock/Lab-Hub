# FrameLab / Tools

| Module | What it does |
| --- | --- |
| `Store` | Binary entries stored in the place as Base64 ModuleScripts (or StringValues when written from a running game). |
| `Importer` | Studio: pick pictures and videos from disk and store them under `Data/`. 360p and 240p videos keep a smaller copy too, for devices that can't keep up. |
| `ImportJob` | The video work that can be split up: decodes any run of frames from the key frame before it and encodes it at each size. |
| `ImportPool` | In a running game, encodes the parts of an MP4 / MOV import on several Actors at once (`Config.ImportWorkers`). |
| `ImportWorker` | The script each of those Actors runs (a switched-off template here; `ImportPool` clones it). |
| `Live` | Streams: an HLS address, or a video played with the TV's Stream switch, converted on the import workers only around where it is being watched. |
| `Net` | Sends big data only to the client that asks for it: video bytes in ranges (the part being watched first, within `Config.VideoCacheMB`), pictures, lists. |
| `TVTool` | The TV tool's behaviour on the client: set the TV down. |
| `SprayTool` | The Spray Paint tool's behaviour on the client: pick a picture, decal or URL and spray a surface. |

The tools themselves are built from `LabHub/Blueprints.luau`; `Runtime/Client/ToolBinder` attaches `TVTool` and `SprayTool` to them.
