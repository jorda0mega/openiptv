#!/bin/zsh
# A film test on the feeds the helper at FEED hands out (the real ones, or the test server's).
# TEST=testFilmOnThisLink (the baseline: what a viewer sees today, the default) or
# testFilmBufferingAsSeenNow (each moment the old way and now).
# LINKS="none far worst" (scripts/slow_link.py): a run on each link, through the throttling proxy
# on PROXY_PORT with that profile (none: no proxy), its lines marked with it. TLS goes through
# the proxy untouched. MOCK (the test server's address) with PROFILE: the test server's own
# profile for the whole run.
set -u
APPLE=$(cd "$(dirname "$0")/.." && pwd)
DD=${DD:-/tmp/openiptv/dd-ios}
PHONE=${PHONE:-8D05A43B-1F37-4121-86D6-1E95520EC19B}
OWNER=${OWNER:-film-buffering-real}
TEST=${TEST:-testFilmOnThisLink}
LOCK=/tmp/openiptv/sim.lock
BUILD_LOCK=/tmp/openiptv/build.lock
PROXY_PORT=${PROXY_PORT:-8859}
export TEST_RUNNER_REAL_FEED=${FEED:-http://127.0.0.1:8799}
export TEST_RUNNER_FILM_BUFFERING_SECONDS=${SECONDS_PLAYED:-240}
free_mb() { df -m /tmp | awk 'NR == 2 { print $4 }'; }
stop_proxy() { kill $(lsof -t -iTCP:$PROXY_PORT -sTCP:LISTEN) 2>/dev/null && sleep 1; }

curl -sf -o /dev/null $TEST_RUNNER_REAL_FEED/emby || { echo "the logins helper isn't running"; exit 1; }
[ -n "${MOCK:-}" ] && { curl -sf -o /dev/null "$MOCK/mock/profile?name=${PROFILE:-none}" || { echo "the test server took no profile"; exit 1; }; }
[ $(free_mb) -ge 3500 ] || { echo "$(free_mb) MB free, a build needs 3500: not run"; exit 1; }
cd $APPLE
echo "$(git rev-parse --short HEAD) $(date '+%H:%M') $TEST"
until mkdir $BUILD_LOCK 2>/dev/null; do echo "build lock held by $(cat $BUILD_LOCK/owner 2>/dev/null), waiting 60 s"; sleep 60; done
echo $OWNER > $BUILD_LOCK/owner
trap 'rm -rf $BUILD_LOCK' EXIT INT TERM HUP
errors=$(xcodebuild build-for-testing -scheme OpenIPTV -destination "platform=iOS Simulator,id=$PHONE" -derivedDataPath $DD -quiet 2>&1 \
  | grep -E "error:")
rm -rf $BUILD_LOCK
[ -n "$errors" ] && { echo "$errors" | head -5; echo "== build failed: test not run"; exit 1; }

until mkdir $LOCK 2>/dev/null; do echo "lock held by $(cat $LOCK/owner 2>/dev/null), waiting 60 s"; sleep 60; done
echo $OWNER > $LOCK/owner
# Film bytes the relay kept fill the simulator's disk: erased before each link and at the end.
trap 'stop_proxy; xcrun simctl shutdown $PHONE 2>/dev/null; xcrun simctl erase $PHONE 2>/dev/null; rm -rf $LOCK' EXIT INT TERM HUP
for link in ${=LINKS:-none far worst}; do
  [ $(free_mb) -ge 1500 ] || { echo "$(free_mb) MB free: stopped before the $link run"; exit 1; }
  echo "== link $link $(date '+%H:%M')"
  unset TEST_RUNNER_PROXY TEST_RUNNER_PROXY_PLAIN
  if [ $link != none ]; then
    python3 -u $APPLE/../scripts/throttle_proxy.py $PROXY_PORT $link > /tmp/openiptv/proxy-$PROXY_PORT.log 2>&1 &
    for _ in {1..20}; do lsof -t -iTCP:$PROXY_PORT -sTCP:LISTEN >/dev/null && break; sleep 0.5; done
    export TEST_RUNNER_PROXY=127.0.0.1:$PROXY_PORT
    # Plain HTTP carries the key in clear: through the proxy only for the test server.
    [ -n "${MOCK:-}" ] && export TEST_RUNNER_PROXY_PLAIN=1
  fi
  for attempt in 1 2 3; do
    xcrun simctl shutdown $PHONE 2>/dev/null
    [ $attempt = 1 ] && xcrun simctl erase $PHONE 2>/dev/null
    xcrun simctl boot $PHONE 2>/dev/null; xcrun simctl bootstatus $PHONE -b >/dev/null 2>&1; sleep 5
    out=$(xcodebuild test-without-building -scheme OpenIPTV -destination "platform=iOS Simulator,id=$PHONE" -derivedDataPath $DD \
      "-only-testing:OpenIPTV UITests/RealFeedFilmTests/$TEST" 2>&1)
    if print -r -- "$out" | grep -q "Failed to get list of active applications"; then echo "(start-up error, attempt $attempt)"; continue; fi
    break
  done
  print -r -- "$out" | grep -E "REAL |error: -|Test Case .*(passed|failed|skipped)|Executed .* tests?," \
    | sed -E "s/^.*Test Case //; s/^.*(REAL )/\1/; s/^.*error: -/error: -/; s/ \([0-9.]+\) seconds$/ seconds/; s/^/[$link] /" | uniq | head -80
  [ $link != none ] && { stop_proxy; sed "s/^/[$link] /" /tmp/openiptv/proxy-$PROXY_PORT.log | tail -1; }
done
echo "== done $(date '+%H:%M')"
