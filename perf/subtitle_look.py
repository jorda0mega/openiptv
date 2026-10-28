#!/usr/bin/env python3 -I
"""How SubtitleLookTests' subtitles look, from its LOOK lines.

    subtitle_look.py TEST.log [--metric]

Per LOOK line (upright, sideways): from the player's frame readout, where the
build has it, the frame's drawn and shown widths (shown / drawn is how far the
screen scales the subtitles up: 1 is drawn at screen pixels) and the
subtitle's peak against SDR white (the peak code value through the frame's
transfer: BT.1886 for SDR, PQ for HDR10, HLG; SDR white is 203 nits, BT.2408).
From the screenshot: the subtitle's height and how soft its edges are (the
mean width in screen pixels of the rise from 25% to 75% across each strong
edge: about 1 is sharp, 2 or more is soft). --metric adds METRIC lines.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

SDR_WHITE = 203.0


def pq_nits(code):
    m1, m2, c1, c2, c3 = 2610 / 16384, 2523 / 4096 * 128, 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32
    e = max(code, 0) ** (1 / m2)
    return 10000 * (max(e - c1, 0) / (c2 - c3 * e)) ** (1 / m1)


def hlg_nits(code):
    a, b, c = 0.17883277, 0.28466892, 0.55991073
    scene = code ** 2 / 3 if code <= 0.5 else (2.718281828 ** ((code - c) / a) + b) / 12
    return 1000 * scene ** 1.2


def peak_ratio(color, peak):
    code = peak / 255
    if color == "pq":
        return pq_nits(code) / SDR_WHITE
    if color == "hlg":
        return hlg_nits(code) / SDR_WHITE
    return code ** 2.4


def gray(path):
    """The screenshot as grey bytes, as ffmpeg decodes it: it turns a sideways shot by the PNG's orientation,
    so the size comes from a decoded copy, not from the file's header."""
    with tempfile.TemporaryDirectory() as folder:
        bmp = os.path.join(folder, "shot.bmp")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-frames:v", "1", bmp], check=True)
        size = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "json", bmp],
                                         capture_output=True, text=True, check=True).stdout)["streams"][0]
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", bmp, "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                             capture_output=True, check=True).stdout
    return size["width"], size["height"], raw


def edges(path):
    """The subtitle's box (the bright pixels in the lower half) and its mean 25-75% edge width."""
    w, h, px = gray(path)
    rows = [y for y in range(h // 2, h) if sum(1 for x in range(0, w, 2) if px[y * w + x] >= 200) >= 4]
    if not rows:
        return None
    # The longest run of rows with bright pixels: the line of text.
    runs, start = [], rows[0]
    for a, b in zip(rows, rows[1:] + [None]):
        if b != a + 1:
            runs.append((start, a))
            start = b
    top, bottom = max(runs, key=lambda r: r[1] - r[0])
    widths = []
    for y in range(top, bottom + 1):
        line = px[y * w:(y + 1) * w]
        x = 1
        while x < w - 8:
            lo, hi = line[x - 1], max(line[x:x + 8])
            if hi - lo >= 120 and line[x] - lo < (hi - lo) * 0.25:
                a = next((k for k in range(x, x + 8) if line[k] - lo >= (hi - lo) * 0.25), None)
                b = next((k for k in range(x, x + 8) if line[k] - lo >= (hi - lo) * 0.75), None)
                if a is not None and b is not None:
                    # Linear placement of each crossing between its pixels.
                    def cross(k, level):
                        before, after = line[k - 1] - lo, line[k] - lo
                        return k - 1 + (level - before) / (after - before) if after != before else k
                    widths.append(cross(b, (hi - lo) * 0.75) - cross(a, (hi - lo) * 0.25))
                    x = b + 1
                    continue
            x += 1
    return dict(height=bottom - top + 1, edges=len(widths), soft=sum(widths) / len(widths) if widths else None)


def main(argv):
    metric = "--metric" in argv
    for line in open(argv[0], errors="replace"):
        m = re.search(r"LOOK (\w+) frame=(\S+) subtitle=(\w+) shot=(\S+)", line)
        if not m:
            continue
        way, frame, shown, shot = m.groups()
        f = re.match(r"drawn_(\d+)x(\d+)_shown_(\d+)x(\d+)_color_(\w+)_peak_(\d+)", frame)
        e = edges(shot)
        parts = [way, f"subtitle {shown}"]
        if f:
            drawn_w, shown_w, color, peak = int(f.group(1)), int(f.group(3)), f.group(5), int(f.group(6))
            scale, ratio = shown_w / drawn_w, peak_ratio(color, peak)
            parts += [f"drawn {f.group(1)}x{f.group(2)}, shown {f.group(3)}x{f.group(4)}: scaled up {scale:.2f}x",
                      f"{color} peak code {peak}: {ratio:.2f}x SDR white"]
            if metric and way == "sideways":
                print(f"METRIC film.subtitles.scale {scale:.2f} ratio")
                print(f"METRIC film.subtitles.peak_{'hdr' if color in ('pq', 'hlg') else 'sdr'} {ratio:.2f} ratio")
        else:
            parts.append("no frame readout (GPU picture)")
        if e:
            parts.append(f"on screen {e['height']} px tall, edges {e['soft']:.2f} px soft over {e['edges']} edges" if e["soft"]
                         else f"on screen {e['height']} px tall, no edges")
        else:
            parts.append("no subtitle found on screen")
        print(" | ".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
