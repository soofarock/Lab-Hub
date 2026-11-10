# FrameLab / Formats

Picture decoders return an RGBA image; video containers list the frames of a file.

| Module | Format |
| --- | --- |
| `Png` | PNG: every colour type and bit depth, interlaced too, and animated PNG (APNG). |
| `Jpeg` | JPEG: baseline and progressive. |
| `Webp` | WebP: lossy, lossless, transparency and animation. |
| `Gif` | GIF: every frame of an animation, composited. |
| `Bmp` | BMP: palette, RLE, 16 / 24 / 32-bit. |
| `Tga` | TGA: colour-mapped, true-colour and greyscale, raw or RLE. |
| `Inflate` | DEFLATE / zlib decompression (for PNG and FrameLab's own data). |
| `Heif` | HEIC / HEIF (H.265) and AVIF (AV1) photos: grid tiles, cropping, rotation, mirroring and transparency. |
| `Mp4` | MP4 / MOV demuxer: the video track's frames and the audio track. |
| `Webm` | WebM / Matroska (MKV) demuxer, in the same shape as `Mp4`. |
| `Avi` | AVI: MPEG-4 Part 2 (Xvid / DivX), Motion JPEG or uncompressed video; PCM, MP3, MP2 or AC-3 audio. |
| `Mpg` | MPEG program streams (`.mpg`, `.vob`), transport stream files (`.ts`, `.m2ts`) and MPEG video elementary streams. |
| `Ts` | MPEG transport stream segments and HLS playlists (`.m3u8`), for streams. |
