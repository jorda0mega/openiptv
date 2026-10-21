#!/bin/zsh
# make_long_film.sh [out-dir]: a two-hour test film (a test pattern and a tone,
# a keyframe every second, about 110 MB) for the test server to convert the
# way Emby does from deep in a film. For PlayerLookTests/testLowerQualityDeepInAFilmPlaysOn:
#   OPENIPTV_MOCK_VIDEO=<out>/long.mkv TEST_RUNNER_LONG_FILM=1
set -e
out=${1:-/tmp/openreel-media/long}
mkdir -p $out
ffmpeg -v error -y -f lavfi -i "testsrc2=size=320x180:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 60 \
  -c:v libx264 -preset ultrafast -b:v 90k -maxrate 120k -bufsize 240k -g 24 -keyint_min 24 -sc_threshold 0 -pix_fmt yuv420p \
  -c:a aac -b:a 32k -ac 1 $out/minute.mkv
ffmpeg -v error -y -stream_loop 119 -i $out/minute.mkv -c copy $out/long.mkv
rm $out/minute.mkv
echo $out/long.mkv
