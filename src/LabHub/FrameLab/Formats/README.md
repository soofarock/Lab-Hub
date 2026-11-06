# FrameLab / Formats

Picture decoders return an RGBA image; video containers list the frames of a file.

| Module | Format |
| --- | --- |
| `Png` | PNG: every colour type and bit depth, interlaced too. |
| `Jpeg` | JPEG: baseline and progressive. |
| `Webp` | WebP: lossy, lossless, transparency and animation. |
| `Gif` | GIF: every frame of an animation, composited. |
| `Bmp` | BMP: palette, RLE, 16 / 24 / 32-bit. |
| `Tga` | TGA: colour-mapped, true-colour and greyscale, raw or RLE. |
| `Inflate` | DEFLATE / zlib decompression (for PNG and FrameLab's own data). |
| `Mp4` | MP4 / MOV demuxer: the video track's frames and the audio track. |
| `Avi` | AVI: Motion JPEG or uncompressed video, PCM audio. |
