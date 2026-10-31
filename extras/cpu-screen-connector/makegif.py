"""Wall PNGs (cubetest --save) to an animated GIF: python -u makegif.py FRAMES_DIR OUT [FPS].

Frames are 160x160 wall snapshots; the GIF keeps that size (in-game
screens read it crisp at arm's length), runs at 5 fps by default, and
merges consecutive identical frames into one longer delay, which is
where all the savings are (the screen spends most of its life holding
a picture).
"""
import os
import sys
from PIL import Image

src = sys.argv[1]
dst = sys.argv[2]
fps = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
duration = int(round(1000.0 / fps))

files = sorted(f for f in os.listdir(src) if f.endswith(".png"))
if not files:
    raise SystemExit("no PNGs in %s" % src)

frames = []
delays = []
for f in files:
    im = Image.open(os.path.join(src, f)).convert("RGB")
    q = im.quantize(colors=256, method=Image.Quantize.MEDIANCUT)
    if frames and (q.tobytes() == frames[-1].tobytes() or
                   set(q.getpalette()[:768]) == set(frames[-1].getpalette()[:768]) and
                   q.tobytes() == frames[-1].tobytes()):
        delays[-1] += duration
    else:
        frames.append(q)
        delays.append(duration)

frames[0].save(dst, save_all=True, append_images=frames[1:],
              duration=delays, loop=0, optimize=True)
print("wrote %s: %d frame(s) kept of %d, %.1f s shown"
      % (dst, len(frames), len(files), sum(delays) / 1000.0))
