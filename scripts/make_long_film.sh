#!/bin/zsh
# make_long_film.sh [out-dir]: a two-hour test film (a test pattern and a tone,
# about 110 MB) for the test server to convert the way Emby does from deep in
# a film. Its keyframes are 10 s apart, as in a real film, and 40:00 isn't one
# (the nearest before it is 39:51). For PlayerLookTests/testLowerQualityDeepInAFilmPlaysOn:
#   OPENIPTV_MOCK_VIDEO=<out>/long.mkv TEST_RUNNER_LONG_FILM=1
set -e
out=${1:-/tmp/openreel-media/long}
mkdir -p $out
part() {
  ffmpeg -v error -y -f lavfi -i "testsrc2=size=320x180:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t $1 \
    -c:v libx264 -preset ultrafast -b:v 90k -maxrate 120k -bufsize 240k -g 240 -keyint_min 240 -sc_threshold 0 -pix_fmt yuv420p \
    -c:a aac -b:a 32k -ac 1 $out/$2.mkv
}
part 1 lead
part 60 minute
{ echo "file '$out/lead.mkv'"; for i in {1..120}; do echo "file '$out/minute.mkv'"; done } > $out/parts.txt
ffmpeg -v error -y -f concat -safe 0 -i $out/parts.txt -c copy $out/long.mkv
rm $out/lead.mkv $out/minute.mkv $out/parts.txt
echo $out/long.mkv
