# FrameLab

Pictures and video in Roblox GUI without uploading them and without EditableImage. A picture is drawn with gradient strips: Frames whose UIGradient holds up to 20 colour keypoints along a row. Big pictures and 360p video can use block pictures instead: one ImageLabel per 8 × 8 or 4 × 4 block, tinted from a shared pattern image.

`init.luau` is the `FrameLab` module: `FrameLab.init()`, `FrameLab.show`, `FrameLab.play`, `FrameLab.import`, `FrameLab.list`, and lazy access to the modules below. Its attributes are the settings described in `LabHub/Config.luau`.

| Folder / module | What it holds |
| --- | --- |
| [`Formats/`](Formats) | Picture decoders and video containers. |
| [`Image/`](Image) | Resizing, and turning a picture into strips or blocks. |
| [`Render/`](Render) | Drawing strips and blocks as GUI objects. |
| [`Video/`](Video) | Video decoding, FrameLab's video formats, and the video player. |
| [`Tools/`](Tools) | Storage in the place, importing, networking, and the TV and Spray Paint tool behaviour. |
| [`Data/`](Data) | Imported pictures and videos stored in the place. |
| [`Runtime/`](Runtime) | What runs in a game: TVs, sprays, synced screens, the data manager, settings and tool access. |
| `Sync.luau` | Server-authoritative video playback: the server writes a few attributes on a screen and every client plays it on the server's playhead. |
