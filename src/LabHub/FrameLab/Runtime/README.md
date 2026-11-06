# FrameLab / Runtime

The modules that run in a game. `FrameLab.init()` (called by `LabHub.start()`) requires every module in `Server/` or `Client/`, depending on the side, and runs each in its own thread. Each one returns `function(FrameLab)`.

- [`Server/`](Server): media requests, synced screens, TVs, sprays, the data library, settings and tool access.
- [`Client/`](Client): synced screens, TV controls, sprays, the panels and the tool behaviour.
