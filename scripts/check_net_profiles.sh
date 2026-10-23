#!/bin/zsh
# check_net_profiles.sh <film> [profiles]: each timing profile measured on the test server (port
# PORT, 8858 unless set) as net_profile_check.py sees it, then with only its server half there and
# its link half carried by the throttling proxy (the port after it): the two should agree. Numbers only.
set -u
film=$1
here=$(cd "$(dirname "$0")" && pwd)
port=${PORT:-8858} proxy=$((${PORT:-8858} + 1))
OPENIPTV_MOCK_VIDEO=$film python3 -u $here/mock_server.py $port > /dev/null 2>&1 &
stop() { kill $(lsof -t -iTCP:$port -sTCP:LISTEN) $(lsof -t -iTCP:$proxy -sTCP:LISTEN) 2>/dev/null; }
trap stop EXIT INT TERM HUP
for _ in {1..20}; do curl -sf -o /dev/null http://127.0.0.1:$port/mock/mark && break; sleep 0.5; done
for profile in ${=2:-real-quiet real-busy far phone worst}; do
  curl -sf -o /dev/null "http://127.0.0.1:$port/mock/profile?name=$profile"
  echo "== $profile, test server"
  python3 $here/net_profile_check.py $port
  curl -sf -o /dev/null "http://127.0.0.1:$port/mock/profile?name=$profile&link=none"
  python3 -u $here/throttle_proxy.py $proxy $profile > /dev/null &
  for _ in {1..20}; do lsof -t -iTCP:$proxy -sTCP:LISTEN >/dev/null && break; sleep 0.5; done
  echo "== $profile, the server half on the test server, the link half on the proxy"
  python3 $here/net_profile_check.py $port --proxy $proxy
  kill $(lsof -t -iTCP:$proxy -sTCP:LISTEN) 2>/dev/null
  sleep 1
done
