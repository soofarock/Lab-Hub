# FrameLab / Tools

| Module | What it does |
| --- | --- |
| `Store` | Binary entries stored in the place as Base64 ModuleScripts (or StringValues when written from a running game). |
| `Importer` | Studio: pick pictures and videos from disk and store them under `Data/`. |
| `Net` | Sends big data only to the client that asks for it: video bytes in ranges, pictures, lists. |
| `TVTool` | The TV tool's behaviour on the client: set the TV down. |
| `SprayTool` | The Spray Paint tool's behaviour on the client: pick a picture, decal or URL and spray a surface. |

The tools themselves are built from `LabHub/Blueprints.luau`; `Runtime/Client/ToolBinder` attaches `TVTool` and `SprayTool` to them.
