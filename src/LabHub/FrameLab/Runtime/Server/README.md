# FrameLab / Runtime / Server

| Module | What it does |
| --- | --- |
| `Media` | Makes FrameLab's remotes and answers requests for videos and pictures, including in-game URL imports. |
| `FrameLabServer` | Keeps the playback state of synced screens (instances tagged `FrameLab`). The server never decodes video. |
| `TV` | Placed TVs: setting one down from the tool, its owner's controls, picking it back up. |
| `Spray` | Spray Paint: places sprays on surfaces and checks who may spray what. |
| `Library` | The data manager's server side: import records kept in a DataStore (when `LibraryDataStore` is on). |
| `Settings` | The settings panel's server side: applies changes, saves them to a DataStore, applies the saved ones at start. |
| `ToolAccess` | Builds the TV and Spray Paint tools and hands them out according to `TVToolAccess` / `SprayToolAccess`. |
