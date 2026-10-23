#!/bin/zsh
# check_net_profiles.sh <film> [profiles]: each timing profile measured on the test server (port
# 8858) as net_profile_check.py sees it, then with only its server half there and its link half
# carried by the throttling proxy (8859): the two should agree. Numbers only.
set -u
film=$1
here=$(cd "$(dirname "$0")" && pwd)
OPENIPTV_MOCK_VIDEO=$film python3 -u $here/mock_server.py 8858 > /dev/null 2>&1 &
stop() { kill $(lsof -t -iTCP:8858 -sTCP:LISTEN) $(lsof -t -iTCP:8859 -sTCP:LISTEN) 2>/dev/null; }
trap stop EXIT INT TERM HUP
for _ in {1..20}; do curl -sf -o /dev/null http://127.0.0.1:8858/mock/mark && break; sleep 0.5; done
for profile in ${=2:-real-quiet real-busy far worst}; do
  curl -sf -o /dev/null "http://127.0.0.1:8858/mock/profile?name=$profile"
  echo "== $profile, test server"
  python3 $here/net_profile_check.py 8858
  curl -sf -o /dev/null "http://127.0.0.1:8858/mock/profile?name=$profile&link=none"
  python3 -u $here/throttle_proxy.py 8859 $profile > /dev/null &
  for _ in {1..20}; do lsof -t -iTCP:8859 -sTCP:LISTEN >/dev/null && break; sleep 0.5; done
  echo "== $profile, the server half on the test server, the link half on the proxy"
  python3 $here/net_profile_check.py 8858 --proxy 8859
  kill $(lsof -t -iTCP:8859 -sTCP:LISTEN) 2>/dev/null
  sleep 1
done
