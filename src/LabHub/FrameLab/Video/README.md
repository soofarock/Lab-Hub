# FrameLab / Video

| Module | What it does |
| --- | --- |
| `H264` | H.264 / AVC decoder (Baseline, Main and High profiles). |
| `Hevc` | H.265 / HEVC decoder (Main and Main 10), for videos and HEIC photos. |
| `Vp9` | VP9 decoder (profile 0), for WebM / MKV. |
| `Vp8` | VP8 decoder, for WebM / MKV. |
| `Av1` | AV1 decoder (Main, High and Professional profiles, 8 and 10 bits, every coding tool including film grain), for videos and AVIF photos. Split over `Av1Post` (in-loop filters and film grain), `Av1Transform` (inverse transforms), `Av1Tables` (default probabilities and constant tables) and `Av1QuantMatrix` (quantizer matrices, loaded only by streams that use them), so each module stays under Roblox's script size limit. |
| `Mpeg2` | MPEG-1 / MPEG-2 video decoder (Main profile), for `.mpg`, `.vob` and transport streams. |
| `Mpeg4` | MPEG-4 Part 2 decoder (Simple and Advanced Simple profile: Xvid, DivX), for AVI, MP4 and MKV. |
| `Stream` | FrameLab's video stream (`FLV1`): the pictures in a form that is cheap to draw. Opens every kind of video, and picks the size of a video kept at several (`deviceLines`, `Config.VideoRendition`). |
| `Flv2` | FrameLab's compact video codec (`FLV2`) for long videos, encoded in parts at once (`assemble`), and the set of sizes one video can be kept at (`FLVS`). |
| `Player` | The video player: fits strips (or blocks) to each frame at run time, within a time and object budget, and keeps sound in step. |
| `AsyncReader` | Decodes an FLV2 video on a worker thread ahead of the player, so the game's frames only draw. |
| `DecodeWorker` | The script `AsyncReader`'s workers run (a switched-off template here). |
| `DirectReader` | A stream decoded on the client itself (H.264 from HLS segments), on worker threads, one segment ahead. |
| `TsDecodeWorker` | The script `DirectReader`'s workers run (a switched-off template here). |
| `BlockFitWorker` | Works out the 8 x 8 blocks of one stripe of each picture for the block player, in parallel (a switched-off template here). |
| `BlockStream` | Block streams for phones: the block picture is worked out on the server, so the client only sets the blocks that change. |
| `StreamSound` | The sound of a stream, as an AudioLab clip that fills in while it plays. |
