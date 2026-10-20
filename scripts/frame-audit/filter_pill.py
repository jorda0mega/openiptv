"""filter_pill.py film.mp4 filter-geometry.json: each Search filter tap moves
the white pill first. The film is of
SearchStabilityTests/testFilterPillMovesFirst (record.sh), which taps the
filters 6 times and writes where the pills and the results are (in points).
For each move of the pill: it must be a slide (4 frames or more, not a jump),
miss at most one 60 Hz frame on the way, and the results must change, after
its first frame (not before or in it, and not never).
Exit 0: every move; 1: a jump, dropped frames, or results that changed
first or not at all; 2: fewer than 6 moves seen."""
import json, subprocess, sys
import numpy as np

video, geometry = sys.argv[1], json.load(open(sys.argv[2]))
W, H = int(round(geometry["width"])), int(round(geometry["height"]))   # 1 pixel = 1 point
pill_top = int(geometry["pills"][0])
results = slice(int(geometry["results"]) + 8, H - 40)
probe = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                   "frame=pts_time", "-of", "json", video], capture_output=True, text=True).stdout)
times = [float(f["pts_time"]) for f in probe["frames"]]
decoder = subprocess.Popen(["ffmpeg", "-v", "error", "-i", video, "-vf", f"scale={W}:{H},format=gray",
                            "-fps_mode", "passthrough", "-f", "rawvideo", "-"], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL)
FRAME = 1 / 60

# Under the pill's top edge, above its word, only the chosen pill is white.
edges, changes, last = [], [], None
while len(buf := decoder.stdout.read(W * H)) == W * H:
    frame = np.frombuffer(buf, np.uint8).reshape(H, W).astype(np.int16)
    white = (frame[pill_top + 3:pill_top + 8, 10:W - 10] > 128).any(axis=0).nonzero()[0]
    edges.append((int(white.min()), int(white.max())) if len(white) else None)
    changes.append(0.0 if last is None else float(np.abs(frame[results] - last[results]).mean()))
    last = frame
decoder.wait()
times = times[:len(edges)]

moving = []
for n in range(1, len(edges)):
    edge, previous = edges[n], edges[n - 1]
    if edge and previous and max(abs(a - b) for a, b in zip(edge, previous)) > 1:
        moving.append(n)
runs = []
for n in moving:
    if runs and times[n] - times[runs[-1][-1]] < 0.15:
        runs[-1].append(n)
    else:
        runs.append([n])


def slide(run):
    """From one filter to another, the pill at rest for half a second before
    (not the page appearing or the app quitting)."""
    before, after = edges[run[0] - 1], edges[run[-1]]
    rested = all(edges[n] == before for n in range(len(edges)) if times[run[0]] - 0.5 <= times[n] < times[run[0]])
    return bool(before and after) and rested and abs(after[0] - before[0]) > 20


slides = [run for run in runs if slide(run)]

failed = 0
for move in slides:
    start, end = times[move[0]], times[move[-1]]
    listed = [times[n] for n in range(len(edges)) if start - 0.3 <= times[n] <= start + 0.3 and changes[n] > 0.5]
    slots = round((end - start) / FRAME) + 1
    missed = max(0, slots - len(move))
    order = f"changed {(listed[0] - start) / FRAME:+.1f} frames after its first" if listed else "didn't change"
    print(f"{start:6.2f} s: pill moved in {len(move)} of {slots} frames, results {order}")
    if len(move) < 4 or missed > 1 or not listed or listed[0] <= start:
        failed += 1
print(f"{len(slides)} moves, {failed} a jump, with frames dropped, or with results first or unchanged")
sys.exit(2 if len(slides) < 6 else 1 if failed else 0)
