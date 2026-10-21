#!/bin/zsh
# real-feed-prepare-ahead.sh: RealFeedTests/testPrepareAheadAsSeenNow on an iPhone simulator, with the logins from the
# helper on 127.0.0.1:8799 (start it first; FEED=<address> for another helper). Continue Watching's first card stays on
# screen 4 s, plays, then English subtitles go on, twice: as shipped, then as before (nothing ahead, no hidden
# subtitles). Prints only counts and times. -readOnlyServer: nothing is marked
# watched, no resume point moves. Takes the shared simulator lock (owner prepare-films-real) and runs one simulator:
# PHONE, or Test iPhone 3.
set -u
APPLE=$(cd "$(dirname "$0")/.." && pwd)
DD=${DD:-/tmp/openiptv/dd-prepfilms}
PHONE=${PHONE:-8D05A43B-1F37-4121-86D6-1E95520EC19B}
LOCK=/tmp/openiptv/sim.lock
export TEST_RUNNER_REAL_FEED=${FEED:-http://127.0.0.1:8799}

curl -sf -o /dev/null $TEST_RUNNER_REAL_FEED/emby || { echo "the logins helper isn't running on $TEST_RUNNER_REAL_FEED"; exit 1; }
until mkdir $LOCK 2>/dev/null; do echo "lock held by $(cat $LOCK/owner 2>/dev/null), waiting 60 s"; sleep 60; done
echo prepare-films-real > $LOCK/owner
trap 'xcrun simctl shutdown $PHONE 2>/dev/null; rm -rf $LOCK' EXIT INT TERM HUP

cd $APPLE
echo "$(git rev-parse --short HEAD) $(date '+%H:%M')"
errors=$(xcodebuild build-for-testing -scheme OpenIPTV -destination "platform=iOS Simulator,id=$PHONE" -derivedDataPath $DD -quiet 2>&1 \
  | grep -E "error:")
[ -n "$errors" ] && { echo "$errors" | head -5; echo "== build failed: test not run"; exit 1; }
for attempt in 1 2 3; do
  xcrun simctl shutdown $PHONE 2>/dev/null
  xcrun simctl boot $PHONE 2>/dev/null; xcrun simctl bootstatus $PHONE -b >/dev/null 2>&1; sleep 5
  out=$(xcodebuild test-without-building -scheme OpenIPTV -destination "platform=iOS Simulator,id=$PHONE" -derivedDataPath $DD \
    "-only-testing:OpenIPTV UITests/RealFeedTests/testPrepareAheadAsSeenNow" 2>&1)
  if print -r -- "$out" | grep -q "Failed to get list of active applications"; then echo "(start-up error, attempt $attempt)"; continue; fi
  break
done
print -r -- "$out" | grep -E "REAL |error: -|Test Case .*(passed|failed|skipped)|Executed .* tests?," \
  | sed -E 's/^.*Test Case //; s/^.*(REAL )/\1/; s/^.*error: -/error: -/' | head -40
echo "== done $(date '+%H:%M')"
