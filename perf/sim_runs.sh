#!/bin/zsh
# sim_runs.sh <Class/test> <commit>...: one UI test at each commit on one simulator, its METRIC lines saved as
# OUT/<test>-<target>[-TAG]/<commit>/samples.jsonl for perf/perf.py compare.
#   PLATFORM ios (the default: "OpenIPTV Test iPhone 3"), tvos ("OpenIPTV Apple TV") or ipad ("PiP iPad",
#     Picture in Picture's only simulator).
#   FEED unset: the test server, under PROFILE (worst unless set), serving FILM (perf/make_jump_film.sh's film
#     unless set) with SET's settings (/mock/set). FEED set: the real feeds through the logins helper at that
#     address; nothing here reads or prints the logins, and the app reports nothing to the server.
#   Each commit is built in one detached worktree (WT) into one DerivedData folder per platform (DD; for the
#   real feeds dd-ios-real and dd-tv-real, which no helper builds into), this tree's timing tests copied in.
#   JumpTimingTests on the test server: the screen is recorded while JUMPS BEGIN is up, decoded to
#   series.json and deleted (KEEP=1 keeps it), and perf/jumps.py times each tap with the app's log.
#   MPV_LOG=1: libmpv's debug log (a diagnostic run, not a timed one). TEST_RUNNER_* reach the test.
# Run it through perf/run.sh, from a copy: zsh reads a script as it goes, so an edit mid-run breaks it.
set -u
TEST=$1; shift
HERE=$(cd "$(dirname "$0")" && pwd); REPO=${REPO:-$(cd $HERE/.. && pwd)}
NAME=$(basename $REPO)
PLATFORM=${PLATFORM:-ios}
typeset -A SIMS=(ios 8D05A43B-1F37-4121-86D6-1E95520EC19B tvos 180EEA27-C2F9-4FA8-97C7-4DC3F7D7EB9C ipad 6736BB64-4090-4B4C-BA08-495C8FCCCBB4)
SIM=${SIM:-$SIMS[$PLATFORM]}
[ $PLATFORM = tvos ] && { SCHEME="OpenIPTV TV"; TARGET="OpenIPTV TV UITests"; TESTDIR=UITests-tvOS; KIND=tv; } \
  || { SCHEME=OpenIPTV; TARGET="OpenIPTV UITests"; TESTDIR=UITests-iOS; KIND=ios; }
# This tree's timing tests, copied into each commit's tree (they read the app only through its readouts).
TIMING=(TimingCase JumpTimingTests StartTimingTests SubtitleLookTests LiveTimingTests)
DD=${DD:-/tmp/openiptv/dd-$KIND-$([ -n "${FEED:-}" ] && echo real || echo $NAME)}
WT=${WT:-/tmp/openiptv/wt-bisect-$NAME}
OUT=${OUT:-/tmp/openiptv/perf-runs}
FILM=${FILM:-/tmp/openiptv/jump-media/jump.mkv}
PROFILE=${PROFILE:-worst}
TARGET_NAME=$([ -n "${FEED:-}" ] && echo real || echo mock:$PROFILE)
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
[ -n "${FEED:-}" ] || [ -f $FILM ] || { echo "no film at $FILM (perf/make_jump_film.sh)"; exit 1; }
[ -d $WT ] || git -C $REPO worktree add --detach $WT HEAD -q

for commit in "$@"; do
  dir=$OUT/${TEST%%/*}-$PLATFORM-${TARGET_NAME#mock:}${TAG:+-$TAG}/$commit; mkdir -p $dir
  echo "== $commit ${TEST%%/*} $PLATFORM $TARGET_NAME $(date +%H:%M), $(free_mb) MB free"
  git -C $WT checkout -q --detach -f $commit && git -C $WT clean -qfd apple/$TESTDIR
  for file in $TIMING; do [ -f ${TESTS:-$REPO/apple}/$TESTDIR/$file.swift ] && cp ${TESTS:-$REPO/apple}/$TESTDIR/$file.swift $WT/apple/$TESTDIR/; done
  [ -e $WT/apple/Vendor ] || ln -s $VENDOR $WT/apple/Vendor
  (cd $WT/apple && xcodegen generate --spec project.yml --quiet) || { echo "xcodegen failed: $commit skipped"; continue; }
  # A build needs 3500 MB free: wait for other runs to give it back, an hour at most.
  for _ in {1..60}; do [ $(free_mb) -ge 3500 ] && break; echo "$(date +%H:%M) $(free_mb) MB free, a build needs 3500: waiting 60 s"; sleep 60; done
  [ $(free_mb) -ge 3500 ] || { echo "$(free_mb) MB free after an hour: stopped"; exit 1; }
  take /tmp/openiptv/build.lock
  xcodebuild build-for-testing -project $WT/apple/OpenIPTV.xcodeproj -scheme $SCHEME -destination "id=$SIM" \
    -derivedDataPath $DD -quiet > $dir/build.log 2>&1 &
  pid=$!; watchdog $pid 2400 & wait $pid; rc=$?
  give /tmp/openiptv/build.lock
  [ $rc = 0 ] || { grep -m5 "error:" $dir/build.log | sed -E 's#^.*/##'; echo "build failed: $commit skipped"; continue; }

  unset TEST_RUNNER_DEBUG_EMBY TEST_RUNNER_REAL_FEED TEST_RUNNER_MPV_EXTRA
  if [ -n "${FEED:-}" ]; then
    export TEST_RUNNER_REAL_FEED=$FEED TEST_RUNNER_REAL_FEED_CACHE=real
  else
    port=8890; while lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; do port=$((port + 1)); done
    OPENIPTV_MOCK_VIDEO=$FILM OPENIPTV_MOCK_RUNTIME=480 OPENIPTV_MOCK_BITRATE=1600000 OPENIPTV_MOCK_PROFILE=$PROFILE \
      OPENIPTV_MOCK_SEED=${SEED:-1} python3 -u $REPO/scripts/mock_server.py $port > $dir/mock.log 2>&1 &
    mock=$!
    for _ in {1..20}; do curl -sf -o /dev/null "http://127.0.0.1:$port/mock/mark" && break; sleep 0.5; done
    [ -n "${SET:-}" ] && curl -sf -o /dev/null "http://127.0.0.1:$port/mock/set?$SET"
    if [ $PLATFORM = tvos ]; then
      export TEST_RUNNER_REAL_FEED=http://localhost:$port/mock/feed TEST_RUNNER_REAL_FEED_CACHE=mock
    else
      export TEST_RUNNER_DEBUG_EMBY="{\"serverURL\":\"http://127.0.0.1:$port\",\"serverName\":\"Mock\",\"userId\":\"U1\",\"userName\":\"tester\",\"accessToken\":\"tok\"}"
    fi
  fi
  export TEST_RUNNER_LOOK_SHOTS=$dir
  [ "${MPV_LOG:-0}" = 1 ] && export TEST_RUNNER_MPV_EXTRA="log-file=$dir/mpv.log"

  take /tmp/openiptv/sim.lock
  for other in ${(v)SIMS}; do [ $other = $SIM ] || xcrun simctl shutdown $other 2>/dev/null; done
  xcrun simctl shutdown $SIM 2>/dev/null; xcrun simctl erase $SIM 2>/dev/null
  if ! boot120; then
    xcrun simctl shutdown $SIM 2>/dev/null; give /tmp/openiptv/sim.lock; sleep 60; take /tmp/openiptv/sim.lock
    boot120 || { xcrun simctl shutdown $SIM; give /tmp/openiptv/sim.lock; [ -n "${mock:-}" ] && kill $mock; mock=""; echo "boot failed twice: $commit skipped"; continue; }
  fi
  rm -f $dir/test.log $dir/recorder.log $dir/recording.mp4 $dir/mpv.log $dir/perf-log.ndjson $dir/series.json $dir/*.png
  began=$(date '+%Y-%m-%d %H:%M:%S')
  xcodebuild test-without-building -project $WT/apple/OpenIPTV.xcodeproj -scheme $SCHEME -destination "id=$SIM" -derivedDataPath $DD \
    "-only-testing:$TARGET/$TEST" > $dir/test.log 2>&1 &
  pid=$!; watchdog $pid ${LIMIT:-1500} &
  if [ -z "${FEED:-}" ]; then
    ( until grep -q "JUMPS BEGIN" $dir/test.log 2>/dev/null || ! kill -0 $pid 2>/dev/null; do sleep 0.3; done
      kill -0 $pid 2>/dev/null && xcrun simctl io $SIM recordVideo --codec=h264 --force $dir/recording.mp4 2>&1 \
        | perl -MTime::HiRes=time -ne '$|=1; printf "%.3f %s", time, $_' > $dir/recorder.log ) &
  fi
  wait $pid
  pkill -INT -f "recordVideo.*$dir" 2>/dev/null; sleep 3
  # The app's seeks and live opens, with the Mac's time: numbers only, by these two fixed beginnings.
  xcrun simctl spawn $SIM log show --style ndjson --start "$began" \
    --predicate 'eventMessage BEGINSWITH "PERF cache at" OR eventMessage BEGINSWITH "PERF live open"' > $dir/perf-log.ndjson 2>/dev/null
  xcrun simctl shutdown $SIM 2>/dev/null
  give /tmp/openiptv/sim.lock
  [ -n "${mock:-}" ] && kill $mock 2>/dev/null; mock=""
  grep -E "Test Case .*(passed|failed|skipped)|error: -" $dir/test.log | sed -E 's/^.*Test Case //; s#^.*error: -#error: -#; s#/[^ ]*/##g' | head -5
  if [ -s $dir/recording.mp4 ]; then
    python3 -I $HERE/jumps.py decode $dir/recording.mp4 $dir/series.json && { [ "${KEEP:-0}" = 1 ] || rm -f $dir/recording.mp4; }
  fi
  if grep -q "^JUMP [+-]10" $dir/test.log; then
    python3 -I $HERE/jumps.py time $dir/series.json $dir/recorder.log $dir/test.log $dir/perf-log.ndjson --metric > $dir/jumps.txt 2>&1
    grep -E "^[+-]10:" $dir/jumps.txt
  fi
  grep -q "^LOOK " $dir/test.log && python3 -I $HERE/subtitle_look.py $dir/test.log --metric > $dir/look.txt 2>&1 && grep -v "^METRIC" $dir/look.txt
  grep -q "^LIVE " $dir/test.log && python3 -I $HERE/perf.py live $dir/perf-log.ndjson > $dir/live.txt 2>&1
  grep -hE "^(START|JUMP start)" $dir/test.log | sed -E 's/ \| .*//'
  python3 -I $HERE/perf.py samples $dir $commit $TARGET_NAME $PLATFORM
  echo "$(grep -c . $dir/samples.jsonl) samples"
done
echo "== done $(date +%H:%M)"
