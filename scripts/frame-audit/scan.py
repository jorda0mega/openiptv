"""scan.py video.mp4: a simulator recording as a list of rest states (the
screen still for 100 ms or more) and what happened between two of them:
  move   part of the screen came back moved up, down or sideways
         (abrupt: in 2 frames or fewer; animated: longer)
  flash  the screen changed and came back as it was
  blank  a short rest (under half a second), reached and left within a
         second, with much less on screen than the rests around it."""
import json, subprocess, sys
import numpy as np

W, FPS = 216, 30

def frames(path):
    probe = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=width,height", "-of", "json", path], capture_output=True, text=True).stdout)
    w, h = probe["streams"][0]["width"], probe["streams"][0]["height"]
    H = int(round(h * W / w / 2)) * 2
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf", f"fps={FPS},scale={W}:{H},format=gray",
        "-f", "rawvideo", "-"], capture_output=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, H, W).astype(np.int16)

def changed(a, b):
    return float((np.abs(a - b) > 24).mean())

def content(a):
    return float((a > 40).mean())

def shift(a, b, y0, y1, rng=60):
    """Vertical move of b's rows y0..y1 against a: 0 (same), n, or None."""
    target = b[y0:y1]
    base = np.abs(target - a[y0:y1]).mean()
    if base < 3: return 0
    if target.std() < 10: return None
    best, bs = base, 0
    for s in range(-rng, rng + 1):
        if s == 0 or y0 - s < 0 or y1 - s > a.shape[0]: continue
        d = np.abs(target - a[y0 - s:y1 - s]).mean()
        if d < best: best, bs = d, s
    return bs if bs and best < 0.3 * base and best < 6 else None

def analyze(f):
    n, H, _ = f.shape
    f = f[:, int(H * 0.06):int(H * 0.97)]        # no status bar, no home bar
    top = int(H * 0.06)
    d = [1.0] + [changed(f[i - 1], f[i]) for i in range(1, n)]
    rests, i = [], 0
    while i < n:                                  # runs of still frames
        j = i
        while j + 1 < n and d[j + 1] < 0.002: j += 1
        if j - i + 1 >= 3: rests.append((i, j))
        i = j + 1
    events = []
    for (a0, a1), (b0, b1) in zip(rests, rests[1:]):
        a, b, gap = f[a1], f[b0], b0 - a1
        t = round(a1 / FPS, 2)
        if changed(a, b) < 0.003:
            peak = max(changed(a, f[k]) for k in range(a1 + 1, b0)) if gap > 1 else 0
            if peak > 0.01:
                events.append({"t": t, "kind": "flash", "frames": gap - 1, "area": round(peak, 3)})
            continue
        moved = []
        for y in range(0, f.shape[1] - 30, 30):
            s = shift(a, b, y, y + 30)
            if s: moved.append((y + top, s))
        if moved:
            events.append({"t": t, "kind": "move", "abrupt": gap <= 2, "frames": gap,
                           "bands": len(moved), "px": sorted({s for _, s in moved})[:6],
                           "from_y": moved[0][0], "to_y": moved[-1][0]})
    for (p, (a0, a1), q) in zip(rests, rests[1:], rests[2:]):
        if q == rests[-1]: continue               # the test's end: the app quits
        if a1 - a0 + 1 < 15 and a0 - p[1] <= 30 and q[0] - a1 <= 30:
            c, cp, cq = content(f[a0]), content(f[p[1]]), content(f[q[0]])
            if c < 0.5 * cp and c < 0.5 * cq:
                events.append({"t": round(a0 / FPS, 2), "kind": "blank", "frames": a1 - a0 + 1,
                               "content": round(c, 3), "around": [round(cp, 3), round(cq, 3)]})
    return sorted(events, key=lambda e: e["t"]), len(rests)

def main(path):
    f = frames(path)
    events, rests = analyze(f)
    print(json.dumps({"video": path, "frames": len(f), "rests": rests, "events": events}))

if __name__ == "__main__":
    main(sys.argv[1])
