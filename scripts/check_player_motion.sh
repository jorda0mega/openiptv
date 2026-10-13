#!/bin/zsh
# Regression check for the player's motion (UI tests can't see it: they wait
# for animations to end). Records the iPhone simulator while
# PlayerLookTests/testPageReadyWhenPlayerCloses opens and closes the player,
# then measures when each of 8 horizontal bands of the screen changes.
# A fade changes every band at about the same frame; the old slide up
# changed the bottom band 5 frames before the top one.
#
# Usage: scripts/check_player_motion.sh <iPhone simulator UDID> <test account JSON>
set -e
udid=$1; account=$2
out=/tmp/openiptv/motion-check; mkdir -p $out; rm -f $out/motion.mp4
cd "${0:A:h}/../apple"
xcrun simctl io $udid recordVideo --codec h264 --force $out/motion.mp4 > $out/record.log 2>&1 &
recorder=$!
sleep 2
TEST_RUNNER_DEBUG_EMBY="$account" xcodebuild test -scheme OpenIPTV -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath /tmp/openiptv/dd-imdb -only-testing:"OpenIPTV UITests/PlayerLookTests/testPageReadyWhenPlayerCloses" > $out/test.log 2>&1
kill -INT $recorder; wait $recorder 2>/dev/null || true
python3 -I - $out/motion.mp4 <<'PY'
import re, subprocess, sys
# For each transition: the frame where each of 8 horizontal bands is halfway
# between its brightness before and after. A fade: every band at about the
# same frame. A slide up: the bottom band first, the top band last.
video, n = sys.argv[1], 8
series = []
for b in range(n):
    text = subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-vf",
        f"fps=30,crop=iw:ih/{n}:0:{b}*ih/{n},signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-",
        "-f", "null", "-"], capture_output=True, text=True).stdout
    series.append([float(m.group(1)) for m in re.finditer(r"YAVG=([\d.]+)", text)])
frames = min(map(len, series))
moving = [i for i in range(1, frames) if any(abs(s[i] - s[i-1]) > 6 for s in series)]
runs = []
for i in moving:
    if runs and i - runs[-1][-1] <= 4: runs[-1].append(i)
    else: runs.append([i])
problems = []
checked = []
# The last run is the app quitting at the end of the test.
for run in runs[:-1]:
    a, z = max(0, run[0] - 2), min(frames - 1, run[-1] + 2)
    halves = []
    for s in series:
        before, after = s[a], s[z]
        if abs(after - before) < 10:
            halves.append(None)
            continue
        mid = (before + after) / 2
        halves.append(next((i for i in range(a, z + 1) if (s[i] - mid) * (after - before) >= 0), None))
    known = [(b, h) for b, h in enumerate(halves) if h is not None]
    # Whole-screen changes only (the film itself playing changes the middle).
    if len(known) >= 3: checked.append((run, halves, known[0][1] - known[-1][1]))
# The player opening and closing: the last two whole-screen changes.
for run, halves, lag in checked[-2:]:
    print(f"frames {run[0]}-{run[-1]}: halfway frame per band, top to bottom: {halves}")
    if lag >= 3:
        problems.append(f"frames {run[0]}-{run[-1]}: the bottom changed {lag} frames before the top (a slide up)")
print("\n".join(problems) or "OK: no transition slides")
sys.exit(1 if problems else 0)
PY
