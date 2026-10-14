#!/bin/zsh
# record.sh Class/test ...: films each iOS UI test on the simulator PHONE
# (env, a simulator id) with simctl recordVideo, into OUT (default
# /tmp/openiptv/frames). Start scripts/mock_server.py on 8788 first; set
# TEST_RUNNER_DEBUG_EMBY as for the UI tests. Then: python3 scan.py OUT/x.mp4
# (flashes and jumps), or info_open.py for testInfoTextWaitsForThePills.
ZAP=${0:A:h:h:h}
OUT=${OUT:-/tmp/openiptv/frames}; DD=${DD:-/tmp/openiptv/dd-imdb}
: ${PHONE:?set PHONE to a simulator id}
mkdir -p $OUT; cd $ZAP/apple
xcodebuild build-for-testing -scheme OpenIPTV -destination "platform=iOS Simulator,id=$PHONE" -derivedDataPath $DD -quiet 2>&1 | grep -E "error:" | head
for t in "$@"; do
  name=${t//\//-}
  for attempt in 1 2 3; do
    xcrun simctl shutdown all 2>/dev/null
    xcrun simctl boot $PHONE 2>/dev/null; xcrun simctl bootstatus $PHONE -b >/dev/null 2>&1; sleep 5
    xcrun simctl io $PHONE recordVideo --codec h264 --force $OUT/$name.mp4 > /dev/null 2>&1 &
    rec=$!; sleep 2
    out=$(xcodebuild test-without-building -scheme OpenIPTV -destination "platform=iOS Simulator,id=$PHONE" \
      -derivedDataPath $DD "-only-testing:OpenIPTV UITests/$t" 2>&1)
    kill -INT $rec; wait $rec 2>/dev/null
    grep -q "Failed to get list of active applications" <<<"$out" && { echo "(start-up error, attempt $attempt)"; continue; }
    break
  done
  grep -E "Test Case .*(passed|failed|skipped)|error:" <<<"$out" | sed -E 's/^.*Test Case //' | head -5
done
