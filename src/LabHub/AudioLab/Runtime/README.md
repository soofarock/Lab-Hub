# AudioLab / Runtime

The modules that run in a game. `AudioLab.init()` (called by `LabHub.start()`) requires every module in `Server/` or `Client/`, depending on the side, and runs each in its own thread. Each one returns `function(AudioLab)`.

- [`Server/`](Server): playback sync, the Studio import server and the audio preload.
- [`Client/`](Client): the players for tagged instances, the music player and the preload loader.
