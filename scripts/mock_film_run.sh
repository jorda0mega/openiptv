#!/bin/zsh
# mock_film_run.sh <profile> <out.txt>: the film runner (apple/scripts/real-feed-film-buffering.sh) on the
# test server (port 8858, its own account at /mock/feed) under that profile of net_profiles.json, the
# server carrying its link too (LINKS=none), with the net film (make_net_film.sh) and m7 in Continue
# Watching 3:36 in. TEST and SEED as the runner and the test server take them. Prints and saves the
# runner's lines.
set -u
profile=$1 out=$2
here=$(cd "$(dirname "$0")" && pwd)
media=${MEDIA:-/tmp/openiptv/net-media}
[ -f $media/net.mkv ] || { echo "no film at $media/net.mkv (make_net_film.sh)"; exit 1; }
lsof -t -iTCP:8858 -sTCP:LISTEN >/dev/null && { echo "port 8858 is taken"; exit 1; }
[ -z "$(xcrun simctl list devices booted | grep -E '\(Booted\)')" ] || { echo "a simulator is running: not run"; exit 1; }
env "OPENIPTV_MOCK_VIDEO=$media/net.mkv" "OPENIPTV_MOCK_RUNTIME=900" "OPENIPTV_MOCK_BITRATE=16000000" \
  "OPENIPTV_MOCK_COUNTRIES=United States of America" "OPENIPTV_MOCK_SUBTITLE_FILES=eng|SDH|$media/sdh.srt" \
  "OPENIPTV_MOCK_SEED=${SEED:-1}" python3 -u $here/mock_server.py 8858 > /dev/null 2>&1 &
trap 'kill $(lsof -t -iTCP:8858 -sTCP:LISTEN) 2>/dev/null' EXIT INT TERM HUP
for _ in {1..20}; do curl -sf -o /dev/null "http://127.0.0.1:8858/mock/mark" && break; sleep 1; done
curl -sf -o /dev/null "http://127.0.0.1:8858/mock/set?home_delay=6&wide_pictures=1&watched_elsewhere=m7&emby_convert=1"
curl -sf -o /dev/null -X POST -H "X-Emby-Token: tok" -H "Content-Type: application/json" \
  -d '{"ItemId": "m7", "PositionTicks": 2160000000}' "http://127.0.0.1:8858/emby/Sessions/Playing/Stopped"
FEED=http://localhost:8858/mock/feed MOCK=http://127.0.0.1:8858 PROFILE=$profile LINKS=none OWNER=fsr-mock \
  TEST_RUNNER_REAL_FEED_CACHE=mock-net zsh $here/../apple/scripts/real-feed-film-buffering.sh | tee $out
