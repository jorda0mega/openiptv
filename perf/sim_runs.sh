#!/bin/zsh
# sim_runs.sh <Class/test> <commit>...: one of this tree's timing UI tests (JumpTimingTests/testTenSecondJumps,
# StartTimingTests/testStarts, SubtitleLookTests/testSubtitleLook with FILM one of perf/make_look_films.sh's) at each commit, on the iPhone simulator, against the test server under PROFILE
# (worst unless set) with perf/make_jump_film.sh's film. Each commit is built in one detached worktree (WT)
# into one DerivedData folder (DD), with this tree's timing tests copied in. Results go to OUT/<commit>/:
# build.log, test.log, and samples.jsonl (perf/perf.py parse). JumpTimingTests: the screen is recorded
# while JUMPS BEGIN is up, decoded to series.json, and perf/jumps.py times each tap with the app's log (jumps.txt); the recording is deleted
# (KEEP=1 keeps it). SET: test server settings (/mock/set). MPV_LOG=1: libmpv's debug log in OUT/<commit>/
# (a diagnostic run, not a timed one: the log slows libmpv down). TEST_RUNNER_* reach the test.
# Run it from a copy (perf/run.sh does): zsh reads a script as it goes, so an edit mid-run breaks it.
set -u
TEST=$1; shift
HERE=$(cd "$(dirname "$0")" && pwd); REPO=${REPO:-$(cd $HERE/.. && pwd)}
NAME=$(basename $REPO)
WT=${WT:-/tmp/openiptv/wt-bisect-$NAME}
DD=${DD:-/tmp/openiptv/dd-ios-$NAME}
SIM=${SIM:-8D05A43B-1F37-4121-86D6-1E95520EC19B}
OUT=${OUT:-/tmp/openiptv/perf-runs}
FILM=${FILM:-/tmp/openiptv/jump-media/jump.mkv}
PROFILE=${PROFILE:-worst}
OWNER="perf-evals $NAME"
VENDOR=$(readlink $REPO/apple/Vendor)
free_mb() { df -m /tmp | awk 'NR == 2 { print $4 }'; }
take() { until mkdir "$1" 2>/dev/null; do echo "$(date +%H:%M) $(basename $1) held by $(cat "$1/owner" 2>/dev/null), waiting 60 s"; sleep 60; done; echo "$OWNER" > "$1/owner"; }
give() { [ "$(cat "$1/owner" 2>/dev/null)" = "$OWNER" ] && { rm -f "$1/owner"; rmdir "$1"; }; }
boot120() {
  ( xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null 2>&1 ) &
  local pid=$! t=0
  while kill -0 $pid 2>/dev/null; do
    [ $t -ge 120 ] && { pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null; return 1; }
    sleep 2; t=$((t + 2))
  done
}
watchdog() { local pid=$1 limit=$2 t=0; while kill -0 $pid 2>/dev/null; do sleep 5; t=$((t + 5)); [ $t -ge $limit ] && { kill $pid; echo "watchdog: stopped after $limit s"; }; done; }
cleanup() {
  pkill -INT -f "recordVideo.*$OUT" 2>/dev/null
  [ -n "${mock:-}" ] && kill $mock 2>/dev/null
  xcrun simctl shutdown $SIM 2>/dev/null
  give /tmp/openiptv/build.lock; give /tmp/openiptv/sim.lock
}
trap cleanup EXIT INT TERM HUP
[ -f $FILM ] || { echo "no film at $FILM (perf/make_jump_film.sh)"; exit 1; }
[ -d $WT ] || git -C $REPO worktree add --detach $WT HEAD -q

for commit in "$@"; do
  dir=$OUT/${TEST%%/*}-$PROFILE${TAG:+-$TAG}/$commit; mkdir -p $dir
  echo "== $commit ${TEST%%/*} $PROFILE $(date +%H:%M), $(free_mb) MB free"
  git -C $WT checkout -q --detach -f $commit && git -C $WT clean -qfd apple/UITests-iOS
  cp ${TESTS:-$REPO/apple/UITests-iOS}/{TimingCase,JumpTimingTests,StartTimingTests,SubtitleLookTests}.swift $WT/apple/UITests-iOS/
  [ -e $WT/apple/Vendor ] || ln -s $VENDOR $WT/apple/Vendor
  (cd $WT/apple && xcodegen generate --spec project.yml --quiet) || { echo "xcodegen failed: $commit skipped"; continue; }
  # A build needs 3500 MB free: wait for other runs to give it back, an hour at most.
  for _ in {1..60}; do [ $(free_mb) -ge 3500 ] && break; echo "$(date +%H:%M) $(free_mb) MB free, a build needs 3500: waiting 60 s"; sleep 60; done
  [ $(free_mb) -ge 3500 ] || { echo "$(free_mb) MB free after an hour: stopped"; exit 1; }
  take /tmp/openiptv/build.lock
  xcodebuild build-for-testing -project $WT/apple/OpenIPTV.xcodeproj -scheme OpenIPTV -destination "id=$SIM" \
    -derivedDataPath $DD -quiet > $dir/build.log 2>&1 &
  pid=$!; watchdog $pid 2400 & wait $pid; rc=$?
  give /tmp/openiptv/build.lock
  [ $rc = 0 ] || { grep -m5 "error:" $dir/build.log; echo "build failed: $commit skipped"; continue; }

  port=8890; while lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; do port=$((port + 1)); done
  OPENIPTV_MOCK_VIDEO=$FILM OPENIPTV_MOCK_RUNTIME=480 OPENIPTV_MOCK_BITRATE=1600000 OPENIPTV_MOCK_PROFILE=$PROFILE \
    OPENIPTV_MOCK_SEED=${SEED:-1} python3 -u $REPO/scripts/mock_server.py $port > $dir/mock.log 2>&1 &
  mock=$!
  for _ in {1..20}; do curl -sf -o /dev/null "http://127.0.0.1:$port/mock/mark" && break; sleep 0.5; done
  [ -n "${SET:-}" ] && curl -sf -o /dev/null "http://127.0.0.1:$port/mock/set?$SET"
  export TEST_RUNNER_DEBUG_EMBY="{\"serverURL\":\"http://127.0.0.1:$port\",\"serverName\":\"Mock\",\"userId\":\"U1\",\"userName\":\"tester\",\"accessToken\":\"tok\"}"
  export TEST_RUNNER_LOOK_SHOTS=$dir
  [ "${MPV_LOG:-0}" = 1 ] && export TEST_RUNNER_MPV_EXTRA="log-file=$dir/mpv.log" || unset TEST_RUNNER_MPV_EXTRA

  take /tmp/openiptv/sim.lock
  xcrun simctl shutdown $SIM 2>/dev/null; xcrun simctl erase $SIM 2>/dev/null
  if ! boot120; then
    xcrun simctl shutdown $SIM 2>/dev/null; give /tmp/openiptv/sim.lock; sleep 60; take /tmp/openiptv/sim.lock
    boot120 || { xcrun simctl shutdown $SIM; give /tmp/openiptv/sim.lock; kill $mock; mock=""; echo "boot failed twice: $commit skipped"; continue; }
  fi
  rm -f $dir/test.log $dir/recorder.log $dir/recording.mp4 $dir/mpv.log $dir/seeks.ndjson $dir/series.json
  began=$(date '+%Y-%m-%d %H:%M:%S')
  xcodebuild test-without-building -project $WT/apple/OpenIPTV.xcodeproj -scheme OpenIPTV -destination "id=$SIM" -derivedDataPath $DD \
    "-only-testing:OpenIPTV UITests/$TEST" > $dir/test.log 2>&1 &
  pid=$!; watchdog $pid ${LIMIT:-1500} &
  ( until grep -q "JUMPS BEGIN" $dir/test.log 2>/dev/null || ! kill -0 $pid 2>/dev/null; do sleep 0.3; done
    kill -0 $pid 2>/dev/null && xcrun simctl io $SIM recordVideo --codec=h264 --force $dir/recording.mp4 2>&1 \
      | perl -MTime::HiRes=time -ne '$|=1; printf "%.3f %s", time, $_' > $dir/recorder.log ) &
  wait $pid
  pkill -INT -f "recordVideo.*$dir" 2>/dev/null; sleep 3
  # The app's seeks, each with the second it left and the Mac's time (numbers only).
  xcrun simctl spawn $SIM log show --style ndjson --start "$began" --predicate 'eventMessage BEGINSWITH "PERF cache at"' \
    > $dir/seeks.ndjson 2>/dev/null
  xcrun simctl shutdown $SIM 2>/dev/null
  give /tmp/openiptv/sim.lock
  kill $mock 2>/dev/null; mock=""
  grep -E "Test Case .*(passed|failed)|XCTAssert|error: -" $dir/test.log | sed -E 's/^.*Test Case //' | head -5
  if [ -s $dir/recording.mp4 ]; then
    python3 -I $HERE/jumps.py decode $dir/recording.mp4 $dir/series.json && { [ "${KEEP:-0}" = 1 ] || rm -f $dir/recording.mp4; }
    python3 -I $HERE/jumps.py time $dir/series.json $dir/recorder.log $dir/test.log $dir/seeks.ndjson --metric > $dir/jumps.txt 2>&1
    grep -v "^METRIC" $dir/jumps.txt
  fi
  grep -q "^LOOK " $dir/test.log && python3 -I $HERE/subtitle_look.py $dir/test.log --metric > $dir/look.txt 2>&1 && grep -v "^METRIC" $dir/look.txt
  grep -hE "^(START|JUMP start)" $dir/test.log | cut -c1-160
  cat $dir/test.log $dir/jumps.txt $dir/look.txt 2>/dev/null | grep -E "^METRIC " > $dir/metrics.txt
  python3 -I $HERE/perf.py parse $dir/metrics.txt | python3 -I -c "
import json, sys
for line in sys.stdin:
    s = json.loads(line); s.update(commit='$commit', target='mock:$PROFILE', platform='ios'); print(json.dumps(s))" > $dir/samples.jsonl
  echo "$(grep -c . $dir/samples.jsonl) samples"
done
echo "== done $(date +%H:%M)"
