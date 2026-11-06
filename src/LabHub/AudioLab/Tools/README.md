# AudioLab / Tools

| Module | What it does |
| --- | --- |
| `Importer` | Studio: pick files from disk and store them in `Data/` as Base64 ModuleScripts; read them back. |
| `Assets` | Decodes each stored file once per Luau VM and shares the result. |
| `Baker` | Studio: analyse a SoundFont once and store the result in `Data/Banks`, so games load a few kilobytes instead of the whole `.sf2`. |
| `Library` | The list of playable tracks (MIDI songs and clips) for menus and the music player. |
