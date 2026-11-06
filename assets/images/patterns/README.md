# Assets / images / patterns

The block-pattern library, as NumPy arrays: 64 groups × 64 patterns for 8 × 8 blocks and for 4 × 4 blocks. Each pattern pixel is a mix amount from 0 to 1.

| File | Shape | What it holds |
| --- | --- | --- |
| `tree8_top.npy` | 64 × 64 | The 64 group centres for 8 × 8 blocks. |
| `tree8_leaves.npy` | 64 × 64 × 64 | The 64 patterns in each 8 × 8 group. |
| `tree4_top.npy` | 64 × 16 | The 64 group centres for 4 × 4 blocks. |
| `tree4_leaves.npy` | 64 × 64 × 16 | The 64 patterns in each 4 × 4 group. |

`python tools/images/make_images.py patterns` turns them into `FrameLabPatterns.png` and PatternData. `python tools/images/make_images.py train <folder of pictures>` learns a new library from your own pictures.
