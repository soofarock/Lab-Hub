# AudioLab / Util

| Module | What it does |
| --- | --- |
| `ByteReader` | Bounds-checked reads from a buffer; little-endian by default, `*be` variants for big-endian. |
| `ByteWriter` | Growable buffer writer with the same methods, plus back-patching of chunk sizes. |
| `Base64` | RFC 4648 Base64, used to keep binary files and clips as text in ModuleScripts. |
