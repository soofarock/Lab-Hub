"""FrameLab's two uploaded images, and the pattern data that goes with the pattern image.

    python tools/images/make_images.py ramp                       -> assets/images/framelab_ramp.png
    python tools/images/make_images.py patterns                   -> assets/images/FrameLabPatterns.png
                                                                     src/LabHub/FrameLab/Render/PatternData/PatternData1.luau, 2.luau
    python tools/images/make_images.py train <folder of pictures> -> assets/images/patterns/tree{8,4}_{top,leaves}.npy
                                                                     (then run `patterns` again)

Upload the PNGs as Images (Creator Hub > Decals/Images) and put their ids in the FrameLab settings RampImage and
PatternImage. The pattern image and PatternData must come from the same library (re-run `patterns` after `train`).

ramp: 256 x 4, white, alpha 0..255 left to right. A strip is drawn as one ImageLabel of it (Config.RampImage).

patterns: the library of block patterns used for block pictures and block video (FrameLab.Render.Patterns):
  64 groups x 64 patterns of 8 x 8 pixels and the same for 4 x 4, each pixel a mix amount 0..1 (k-means centres of
  real pictures' blocks, normalised along each block's main colour axis). A block is ONE ImageLabel: background
  colour A, the pattern's slice of the image tinted colour B, so pixel = A + pattern * (B - A).
  Image (1024 x 1024 RGBA, white, the pattern in alpha): 8 x 8 patterns in 12-pixel cells (2 pixels of padding, edge
  pixels repeated) 64 to a row from (0, 0); 4 x 4 patterns in 8-pixel cells, 32 to a row from x = 768.
  PatternData: the same values at 4 bits ([tops 8: 64x64][leaves 8: 4096x64][tops 4: 64x16][leaves 4: 4096x16]),
  two values per byte (high nibble first), zlib, base64, split over two ModuleScripts (string size limit).

Needs: numpy, pillow; `train` also needs scikit-learn and scikit-image.
"""
import base64, os, sys, zlib
import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IMAGES = os.path.join(ROOT, "assets", "images")
LIB = os.path.join(IMAGES, "patterns")
DATA_DIR = os.path.join(ROOT, "src", "LabHub", "FrameLab", "Render", "PatternData")


def ramp():
    a = np.zeros((4, 256, 4), np.uint8)
    a[..., :3] = 255
    a[..., 3] = np.arange(256)[None, :]
    os.makedirs(IMAGES, exist_ok=True)
    Image.fromarray(a, "RGBA").save(os.path.join(IMAGES, "framelab_ramp.png"))
    print("wrote assets/images/framelab_ramp.png")


def load_library():
    lib = {}
    for bs in (8, 4):
        top = np.load(os.path.join(LIB, "tree%d_top.npy" % bs))        # 64 x bs*bs
        leaves = np.load(os.path.join(LIB, "tree%d_leaves.npy" % bs))  # 64 x 64 x bs*bs
        lib[bs] = (np.clip(top, 0, 1), np.clip(leaves, 0, 1).reshape(4096, bs * bs))
    return lib


def patterns():
    lib = load_library()
    img = np.zeros((1024, 1024, 4), np.uint8)
    img[..., :3] = 255
    for bs, cell, x0, cols in ((8, 12, 0, 64), (4, 8, 768, 32)):
        pad = (cell - bs) // 2
        leaves = lib[bs][1]
        for idx in range(4096):
            p = np.round(leaves[idx].reshape(bs, bs) * 255).astype(np.uint8)
            p = np.pad(p, pad, mode="edge")
            x, y = x0 + (idx % cols) * cell, (idx // cols) * cell
            img[y:y + cell, x:x + cell, 3] = p
    os.makedirs(IMAGES, exist_ok=True)
    Image.fromarray(img, "RGBA").save(os.path.join(IMAGES, "FrameLabPatterns.png"))

    q = lambda v: np.round(v * 15).astype(np.uint8).ravel()
    vals = np.concatenate([q(lib[8][0]), q(lib[8][1]), q(lib[4][0]), q(lib[4][1])])
    assert len(vals) % 2 == 0
    packed = (vals[0::2] << 4 | vals[1::2]).astype(np.uint8).tobytes()
    text = base64.b64encode(zlib.compress(packed, 9)).decode()
    half = (len(text) // 2) // 4 * 4
    os.makedirs(DATA_DIR, exist_ok=True)
    for i, part in enumerate((text[:half], text[half:]), 1):
        with open(os.path.join(DATA_DIR, "PatternData%d.luau" % i), "w", newline="\n") as fh:
            fh.write("-- FrameLab pattern library data (generated): part %d of 2, base64 of "
                     "zlib-packed 4-bit values\nreturn \"%s\"\n" % (i, part))
    print("wrote assets/images/FrameLabPatterns.png and PatternData1/2.luau (%d values)" % len(vals))


def train(folder):
    # tree-structured library: 64 groups (k-means on all blocks) x 64 patterns (k-means inside each group)
    from sklearn.cluster import MiniBatchKMeans
    from skimage import transform

    def to_alpha(b):
        m = b.mean(1, keepdims=True); d = b - m
        w, v = np.linalg.eigh(np.einsum("npi,npj->nij", d, d)); ax = v[:, :, -1]
        t = np.einsum("npi,ni->np", d, ax)
        lo, hi = t.min(1, keepdims=True), t.max(1, keepdims=True)
        return (t - lo) / np.maximum(hi - lo, 1e-6), (hi - lo)[:, 0]

    def blocks(img, bs):
        h, w = img.shape[0] // bs, img.shape[1] // bs
        return img[:h * bs, :w * bs].reshape(h, bs, w, bs, 3).transpose(0, 2, 1, 3, 4).reshape(h * w, bs * bs, 3).astype(np.float32)

    pics = []
    for f in sorted(os.listdir(folder)):
        try:
            pics.append(np.array(Image.open(os.path.join(folder, f)).convert("RGB")))
        except Exception:
            pass
    assert pics, "no pictures in " + folder
    os.makedirs(LIB, exist_ok=True)
    rng = np.random.default_rng(0)
    for bs in (8, 4):
        allA = []
        for im in pics:
            for s in (1.0, 0.7, 0.5):
                v = im if s == 1 else (transform.resize(im, (int(im.shape[0] * s), int(im.shape[1] * s)), anti_aliasing=True) * 255).astype(np.uint8)
                for off in ((0, 0), (bs // 2, bs // 2)):
                    a, rng_ = to_alpha(blocks(v[off[0]:, off[1]:], bs))
                    allA.append(a[rng_ > 10])
        A = np.concatenate(allA); A = np.concatenate([A, 1 - A])
        if len(A) > 400000:
            A = A[rng.choice(len(A), 400000, replace=False)]
        top = MiniBatchKMeans(64, random_state=0, batch_size=8192, n_init=3, max_iter=100).fit(A)
        lab = top.predict(A)
        leaves = np.zeros((64, 64, bs * bs))
        for g in range(64):
            S = A[lab == g]
            if len(S) < 64:
                S = np.concatenate([S, S + rng.normal(0, 0.02, S.shape)] * (64 // max(len(S), 1) + 1))[:max(64, len(S))]
            leaves[g] = MiniBatchKMeans(64, random_state=0, batch_size=4096, n_init=1, max_iter=80).fit(S).cluster_centers_
        np.save(os.path.join(LIB, "tree%d_top.npy" % bs), np.clip(top.cluster_centers_, 0, 1))
        np.save(os.path.join(LIB, "tree%d_leaves.npy" % bs), np.clip(leaves, 0, 1))
        print("trained %dx%d patterns from %d blocks" % (bs, bs, len(A)))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "ramp":
        ramp()
    elif cmd == "patterns":
        patterns()
    elif cmd == "train" and len(sys.argv) > 2:
        train(sys.argv[2])
    else:
        print(__doc__)
