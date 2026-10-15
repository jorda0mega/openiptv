#!/bin/zsh
# make_speech_film.sh [out-dir]: an eight-minute test film whose sound is
# spoken English lines (macOS `say`) over noise and a hum, with no subtitle
# track of its own, and two subtitle files for it: in-time.srt (the lines'
# true times) and early.srt (every line 6.5 s early, like Asterix and
# Cleopatra's English file). For PlayerLookTests/testSubtitleFileInTimeBySpeech:
#   OPENIPTV_MOCK_VIDEO=<out>/speech.mkv OPENIPTV_MOCK_RUNTIME=480
#   OPENIPTV_MOCK_SUBTITLE_FILES="eng||<out>/early.srt" TEST_RUNNER_SUBTITLE_SPEECH=1
set -e
out=${1:-/tmp/openreel-media/speech}
mkdir -p $out
python3 -I - "$out" <<'PY'
import os, random, subprocess, sys
out = sys.argv[1]
random.seed(5)
lines = ["Where did you put the map", "We leave at dawn, not a minute later", "I told you the bridge was out",
         "Nobody listens to the old man", "Keep your voice down, they can hear us", "That was not part of the plan",
         "Get the horses ready", "How far is the next village", "I am not going back there", "Look, the river is rising",
         "Bring me the letter from the captain", "You should have seen his face"]
work = os.path.join(out, "lines")
os.makedirs(work, exist_ok=True)
cues, t, n = [], 4.0, 0
while t < 470:
    text = random.choice(lines)
    path = os.path.join(work, f"{n}.aiff")
    subprocess.run(["say", "-v", "Samantha", "-o", path, text], check=True)
    length = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                                  capture_output=True, text=True, check=True).stdout)
    if t + length > 476: break
    cues.append((t, t + length, text, path))
    t += length + random.uniform(1.5, 6.0)
    n += 1
def srt(name, shift):
    def ts(x):
        ms = int(round(x * 1000))
        return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"
    with open(os.path.join(out, name), "w") as f:
        for i, (a, b, text, _) in enumerate(cues, 1):
            f.write(f"{i}\n{ts(max(0, a + shift))} --> {ts(max(0, b + shift))}\n{text}\n\n")
srt("in-time.srt", 0)
srt("early.srt", -6.5)
# The lines at their times, over noise and a low hum (music between).
inputs = ["-f", "lavfi", "-i", "anoisesrc=color=pink:amplitude=0.02:duration=480:sample_rate=48000",
          "-f", "lavfi", "-i", "sine=frequency=110:duration=480:sample_rate=48000"]
filters = []
for i, (a, _, _, path) in enumerate(cues):
    inputs += ["-i", path]
    ms = int(a * 1000)
    filters.append(f"[{i + 2}:a]aresample=48000,adelay={ms}|{ms}[l{i}]")
mix = "".join(f"[l{i}]" for i in range(len(cues)))
graph = ";".join(filters + ["[1:a]volume=0.05[hum]", f"[0:a][hum]{mix}amix=inputs={len(cues) + 2}:normalize=0,atrim=0:480,pan=stereo|c0=c0|c1=c0[a]"])
subprocess.run(["ffmpeg", "-v", "error", "-y", *inputs, "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10:duration=480",
                "-filter_complex", graph, "-map", f"{len(cues) + 2}:v", "-map", "[a]",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "35", "-c:a", "aac", "-b:a", "128k",
                os.path.join(out, "speech.mkv")], check=True)
print(f"{len(cues)} lines; {out}/speech.mkv, in-time.srt, early.srt")
PY
