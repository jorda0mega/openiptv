#!/bin/zsh
# mock_film_run.sh <profile> <out.txt>: the film runner (apple/scripts/real-feed-film-buffering.sh) on the
# test server (port PORT, 8858 unless set, its own account at /mock/feed) under that profile of
# net_profiles.json, the server carrying its link too (LINKS=none), with m7 in Continue Watching 3:36 in.
# FILM: net (make_net_film.sh, the default) or open (make_open_film.sh: its header runs past the first
# read, three audio tracks, a sparse Spanish track inside). PLATFORMS ("ios tvos"), NETWORK, METERED_LINKS,
# PHONE_FILMS, TEST, SEED and LOW_DISK as the runner and the test server take them: by default the iPhone
# runs unmetered and then metered over the phone link once per setting, and the Apple TV unmetered.
# Prints and saves the runner's lines.
set -u
profile=$1 out=$2
here=$(cd "$(dirname "$0")" && pwd)
media=${MEDIA:-/tmp/openiptv/net-media}
film=${FILM:-net} port=${PORT:-8858}
[ -f $media/$film.mkv ] || { echo "no film at $media/$film.mkv (make_${film}_film.sh)"; exit 1; }
lsof -t -iTCP:$port -sTCP:LISTEN >/dev/null && { echo "port $port is taken"; exit 1; }
[ -z "$(xcrun simctl list devices booted | grep -E '\(Booted\)')" ] || { echo "a simulator is running: not run"; exit 1; }
env "OPENIPTV_MOCK_VIDEO=$media/$film.mkv" "OPENIPTV_MOCK_RUNTIME=900" "OPENIPTV_MOCK_BITRATE=16000000" \
  "OPENIPTV_MOCK_COUNTRIES=United States of America" "OPENIPTV_MOCK_SUBTITLE_FILES=$([ $film = net ] && echo "eng|SDH|$media/sdh.srt")" \
  "OPENIPTV_MOCK_SEED=${SEED:-1}" python3 -u $here/mock_server.py $port > /dev/null 2>&1 &
trap 'kill $(lsof -t -iTCP:$port -sTCP:LISTEN) 2>/dev/null' EXIT INT TERM HUP
for _ in {1..20}; do curl -sf -o /dev/null "http://127.0.0.1:$port/mock/mark" && break; sleep 1; done
curl -sf -o /dev/null "http://127.0.0.1:$port/mock/set?home_delay=6&wide_pictures=1&watched_elsewhere=m7&emby_convert=1"
curl -sf -o /dev/null -X POST -H "X-Emby-Token: tok" -H "Content-Type: application/json" \
  -d '{"ItemId": "m7", "PositionTicks": 2160000000}' "http://127.0.0.1:$port/emby/Sessions/Playing/Stopped"
FEED=http://localhost:$port/mock/feed MOCK=http://127.0.0.1:$port PROFILE=$profile LINKS=none OWNER=${OWNER:-fsr-mock} \
  PROXY_PORT=${PROXY_PORT:-$((port + 1))} TEST_RUNNER_REAL_FEED_CACHE=mock-net \
  zsh $here/../apple/scripts/real-feed-film-buffering.sh | tee $out
