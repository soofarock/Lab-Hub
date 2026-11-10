# Changelog

## 1.1.0

### New formats
Every decoder is written in Luau and runs in the game, and each was checked against ffmpeg's decoders.

- **Video:** H.265 / HEVC, AV1, VP9, VP8, MPEG-4 Part 2 (Xvid / DivX) and MPEG-1 / MPEG-2.
- **Containers:** WebM / MKV, MPEG program streams (`.mpg`, `.vob`), transport streams (`.ts`, `.m2ts`), and AVI with MPEG-4 Part 2 video.
- **Pictures:** HEIC / HEIF (iPhone photos) and AVIF, with transparency.
- **Animations:** animated PNG (APNG).
- **Sound tracks:** Opus (in MP4, MOV, WebM and Ogg), AC-3 (surround is mixed down to stereo), MP2, and FLAC and Vorbis inside video files.

### Streaming
- HLS addresses (`.m3u8`) play as live streams. The server converts only the parts near where people are watching (`StreamMaxSeconds`).
- The TV's **Stream** switch plays an MP4 / MOV / WebM without importing it whole (`StreamMaxSourceLines`).
- On computers, a client can decode a stream's H.264 itself on worker threads. It falls back to the server's converted copy if it falls behind (`VideoDecode`).
- Phones get block streams: the block picture is worked out on the server, so the phone only sets the blocks that change.
- Streams have sound.
- A jump waits at the new spot until the picture arrives (`SeekHold`).
- Long imported videos stream to the clients that play them, within a memory budget (`VideoCacheMB`). **Labs → Data → Clients** shows each player's use.

### Import and playback
- MP4 / MOV sources up to 1080p are shrunk to the import size as they are read (`ImportMaxVideoLines`).
- In a running game, video imports are split over parallel workers (`ImportWorkers`) and encoded about 30% faster.
- 360p and 240p imports keep a smaller copy (180p / 144p). `VideoRendition` picks which size clients play, and a client that falls behind steps down.
- FLV2 videos are decoded on a worker thread ahead of the player, so the game's frames only draw.
- Slightly better picture at the same size: droppable frames are coded at a lower quality.

### Build
- The release builder accepts switched-off LocalScript templates (the client decode workers).

## 1.0.0

First release.
