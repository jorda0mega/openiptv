#!/bin/zsh
# make_jump_film.sh [out-dir]: an 8 minute 1080p film at 24000/1001 with a keyframe every 24 frames, at 1.6 Mbps
# (under the worst profile's slowest swing), moving everywhere (testsrc2), with a 440 Hz AAC sound. Each frame
# carries its own number in 14 black or white blocks, bit b at x = 137 b, 130 px wide, across its top band
# (y 0 to 150) and again across its bottom band (y 930 to 1080), for perf/jumps.py.
set -e
out=${1:-/tmp/openiptv/jump-media}
mkdir -p $out
[ "${FOURK:-0}" = 1 ] || {
f="testsrc2=size=1920x1080:rate=24000/1001,format=yuv420p"
for b in {0..13}; do
  for y in 0 930; do
    f="$f,drawbox=x=$((b * 137)):y=$y:w=130:h=150:color=black:t=fill"
    f="$f,drawbox=x=$((b * 137)):y=$y:w=130:h=150:color=white:t=fill:enable='mod(floor(n/$((1 << b))),2)'"
  done
done
ffmpeg -v error -y -f lavfi -i "$f" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 480 -map 0:v -map 1:a \
  -c:v libx264 -preset veryfast -b:v 1500k -maxrate 2000k -bufsize 3000k -g 24 -keyint_min 24 -sc_threshold 0 \
  -c:a aac -b:a 96k -ac 2 $out/jump.mkv
}
# FOURK=1: the same at 3840x2160 in 10-bit HEVC, PQ and BT.2020 (HDR10's tags), 10 Mbps, 300 s (jump-4k-hdr.mkv):
# the software picture's heaviest case. Blocks and bands twice the size, so they read the same.
if [ "${FOURK:-0}" = 1 ]; then
  f="testsrc2=size=3840x2160:rate=24000/1001,format=yuv420p"
  for b in {0..13}; do
    for y in 0 1860; do
      f="$f,drawbox=x=$((b * 274)):y=$y:w=260:h=300:color=black:t=fill"
      f="$f,drawbox=x=$((b * 274)):y=$y:w=260:h=300:color=white:t=fill:enable='mod(floor(n/$((1 << b))),2)'"
    done
  done
  f="$f,format=p010le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc"
  ffmpeg -v error -y -f lavfi -i "$f" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 300 -map 0:v -map 1:a \
    -c:v hevc_videotoolbox -profile:v main10 -b:v 10M -maxrate 14M -g 24 -tag:v hvc1 -color_primaries bt2020 -color_trc smpte2084 \
    -colorspace bt2020nc -c:a aac -b:a 96k -ac 2 $out/jump-4k-hdr.mkv
fi
