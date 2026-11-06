# Assets / images

| File | Setting | What it is |
| --- | --- | --- |
| `framelab_ramp.png` | `RampImage` | 256 × 4, white with alpha 0..255 left to right: a strip drawn as one ImageLabel. |
| `FrameLabPatterns.png` | `PatternImage` | 1024 × 1024, white with the pattern in alpha: the 4096 + 4096 block patterns. It goes with `src/LabHub/FrameLab/Render/PatternData`. |
| `labhub_icon.svg` | | The LabHub icon: a circle in four quadrants (video, sound wave, image, plus). |
| `labhub_icon.png` | `HubIcon` | The icon at 512 × 512, the file uploaded for the Labs button. |
| `labhub_icon_256.png` | | The icon at 256 × 256, for the README. |
| [`patterns/`](patterns) | | The pattern library the pattern image is made from. |

`tools/images/make_images.py` makes the ramp, the pattern image and PatternData.
