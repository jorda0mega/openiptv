"""info_open.py film.mp4 info-geometry.json: the Info panel's text isn't
drawn while the pills travel up to it (upright iPhone). The film is of
PlayerLookTests/testInfoTextWaitsForThePills (record.sh), which opens Info
stretched 15 times and writes the final positions (in points) to the json.
Exit 0: never; 1: text drawn while the white Info pill wasn't yet up past
the panel's title (it crossed the text); 2: the pill's travel wasn't seen."""
import json, subprocess, sys
import numpy as np

video, geometry = sys.argv[1], json.load(open(sys.argv[2]))
W = int(round(geometry["width"]))                      # 1 pixel = 1 point
H = int(round(geometry["height"]))
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-vf", f"fps=30,scale={W}:{H}",
                      "-pix_fmt", "rgb24", "-f", "rawvideo", "-"], capture_output=True).stdout
frames = np.frombuffer(raw, np.uint8).reshape(-1, H, W, 3)
ix, iy, iw, ih = geometry["info"]
tx, ty, tw, th = geometry["title"]
sx, sy, sw, sh = geometry["start"]
band = slice(int(ix + 8), int(ix + iw - 8))
area = (slice(int(ty), int(sy)), slice(int(geometry["pillsEnd"] + 12), W - 20))
tops, lits = [], []
for frame in frames:
    low = frame.min(axis=2)                            # white: every channel high
    rows = (low[int(iy) - 10:H - 40, band] > 170).mean(axis=1)
    found = np.nonzero(rows >= 0.5)[0]
    tops.append(int(iy) - 10 + int(found[0]) if len(found) else None)
    lits.append(int((low[area] > 160).sum()))
# The opening: the frames before the pill first rests where it ends (10
# frames running) in which it is white (chosen) all along.
home = [t is not None and abs(t - iy) <= 2 for t in tops]
settled = next((n for n in range(len(home) - 10) if all(home[n:n + 10])), None)
if settled is None:
    print("the Info pill never came to rest where it ends")
    sys.exit(2)
opened = settled
while opened > 0 and tops[opened - 1] is not None:
    opened -= 1
print(f"opening: frames {opened} to {settled} ({opened / 30:.2f} s to {settled / 30:.2f} s)")
travelling = violations = 0
for n in range(opened, settled):
    top, lit = tops[n], lits[n]
    if top is None or top + ih <= ty:
        continue
    travelling += 1                                    # not yet up past the text
    if lit > 15:
        violations += 1
        if violations <= 5:
            print(f"frame {n} ({n / 30:.2f} s): pill top {top} (ends at {iy:.0f}), {lit} text pixels drawn")
print(f"{len(frames)} frames, {travelling} with the pill not yet past the text, {violations} with the text drawn meanwhile")
sys.exit(2 if travelling == 0 else 1 if violations else 0)
