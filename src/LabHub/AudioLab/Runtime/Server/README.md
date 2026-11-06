# AudioLab / Runtime / Server

| Module | What it does |
| --- | --- |
| `AudioLabServer` | Keeps the playback state of synced audio (instances tagged `AudioLab`) and answers the clients' requests. The server never synthesises audio. |
| `AudioLabImportServer` | Studio only: imports files into `Data/` from the music player's import tab. In a live game it does nothing. |
| `PreloadSetup` | Builds `ReplicatedFirst.AudioLabPreload`, one AudioPlayer per generic file, so joining clients start loading the audio first. |
