# AudioLab / Runtime / Client

| Module | What it does |
| --- | --- |
| `AudioLabClient` | Plays the audio of every instance tagged `AudioLab`, on the server's playhead. |
| `AudioLabMusicPlayer` | The music player window (Labs → Music): now playing, seek, volume, the track list, and an import tab in Studio. |
| `PreloadLoader` | Loads the files listed in `ReplicatedFirst.AudioLabPreload` for the active profile, as early as possible. Progress is on that folder's attributes. |
