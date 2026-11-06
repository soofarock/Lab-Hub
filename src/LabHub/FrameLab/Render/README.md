# FrameLab / Render

| Module | What it does |
| --- | --- |
| `Canvas` | A picture made of GUI strips, pooled and reused. Keeps the number of different gradients under Roblox's limit. |
| `Shapes` | Shared gradient shapes for strips past that limit (a tint times a shared shape). |
| `BlockGrid` | A video picture as a fixed grid of blocks, for the block video player. |
| `Patterns` | The pattern library for block pictures: matches a block to one of 4096 patterns. |
| [`PatternData/`](PatternData) | The pattern library's values. |

The pictures these draw with are the uploaded images in `assets/images`: `RampImage` and `PatternImage` in the settings.
