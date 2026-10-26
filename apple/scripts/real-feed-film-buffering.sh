#!/bin/zsh
# A film test on the feeds the helper at FEED hands out (the real ones, or the test server's), on each
# of PLATFORMS ("ios tvos") in turn, the iPhone first, under one simulator lock.
# TEST=testFilmOnThisLink (the baseline on both: what a viewer sees today, the default) or
# testFilmBufferingAsSeenNow (each moment the old way and now, iPhone only).
# LINKS="none far worst" (scripts/net_profiles.json): a run on each link, unmetered, through the throttling
# proxy on PROXY_PORT with that profile's link half (none: no proxy). TLS goes through the proxy untouched.
# NETWORK="unmetered metered" (the iPhone's; lowData too, -debugNetwork): each metered or lowData run goes
# on each of METERED_LINKS ("phone"), once for each of PHONE_FILMS ("none daily wifi", the setting for
# films on a phone network, -phoneNetworkFilms). The Apple TV runs unmetered only. Each line starts
# [platform link network].
# MOCK (the test server's address): each run takes PROFILE's server half (the link's own profile unless
# set), and its link half too on the none link, set afresh as the run starts; after it, what the test
# server did, counts only. Each run says the Mac's free disk: an iPhone fetches no film ahead under
# 2 GB, an Apple TV under 0.5 GB. LOW_DISK=1: the app reads it as under that whatever it is (-lowDisk YES).
# Builds go into folders no other run uses: a real run's into dd-ios-real and dd-tv-real, which no
# helper builds into; a test server run's into dd-ios-<worktree> and dd-tv-<worktree> (DD and TV_DD
# override). Each folder is held from its build to its last run (<folder>.lock), and builds wait for
# the simulator lock too. Each platform's section, and each run, starts with the build stamp of the
# app it runs (scripts/build-stamp.sh), and says whether it is this tree's.
set -u
APPLE=$(cd "$(dirname "$0")/.." && pwd)
WORKTREE=$(basename "$(git -C $APPLE rev-parse --show-toplevel)")
DD=${DD:-/tmp/openiptv/dd-ios-$([ -n "${MOCK:-}" ] && echo $WORKTREE || echo real)}
TV_DD=${TV_DD:-/tmp/openiptv/dd-tv-$([ -n "${MOCK:-}" ] && echo $WORKTREE || echo real)}
PHONE=${PHONE:-8D05A43B-1F37-4121-86D6-1E95520EC19B}
TV=${TV:-180EEA27-C2F9-4FA8-97C7-4DC3F7D7EB9C}
OWNER=${OWNER:-film-buffering-real}
TEST=${TEST:-testFilmOnThisLink}
PLATFORMS=${PLATFORMS:-ios tvos}
NETWORK=${NETWORK:-unmetered metered}
METERED_LINKS=${METERED_LINKS:-phone}
PHONE_FILMS=${PHONE_FILMS:-none daily wifi}
LOCK=/tmp/openiptv/sim.lock
BUILD_LOCK=/tmp/openiptv/build.lock
PROXY_PORT=${PROXY_PORT:-8859}
typeset -A SCHEME=(ios OpenIPTV tvos "OpenIPTV TV") TARGET=(ios "OpenIPTV UITests" tvos "OpenIPTV TV UITests")
typeset -A OS=(ios iOS tvos tvOS) SIM=(ios $PHONE tvos $TV) PRODUCTS=(ios $DD tvos $TV_DD)
typeset -A APP=(ios Debug-iphonesimulator/OpenIPTV.app tvos Debug-appletvsimulator/OpenIPTV.app)
held=()
export TEST_RUNNER_REAL_FEED=${FEED:-http://127.0.0.1:8799}
export TEST_RUNNER_FILM_BUFFERING_SECONDS=${SECONDS_PLAYED:-240}
export TEST_RUNNER_LOW_DISK=${LOW_DISK:-0}
free_mb() { df -m /tmp | awk 'NR == 2 { print $4 }'; }
stop_proxy() { kill $(lsof -t -iTCP:$PROXY_PORT -sTCP:LISTEN) 2>/dev/null && sleep 1; }

curl -sf -o /dev/null $TEST_RUNNER_REAL_FEED/emby || { echo "the logins helper isn't running"; exit 1; }
[ -n "${MOCK:-}" ] && { curl -sf -o /dev/null "$MOCK/mock/profile?name=${PROFILE:-none}" || { echo "the test server took no profile"; exit 1; }; }
far_end() {
  local server=${PROFILE:-$1}
  curl -sf -o /dev/null "$MOCK/mock/profile?name=$server&link=$([ $1 = none ] && echo $server || echo none)"
}
far_end_done() {
  curl -sf "$MOCK/mock/net" | python3 -c '
import json, sys
n = json.load(sys.stdin)
if n["profile"] != "none" or n.get("link", "none") != "none":
    s, l = n["server"], n["net"]
    print("test server %s over %s: %d reads, %d hung, %d reset, %d conversions, %d refused, %d subtitle extractions | "
          "link %s MB/s while carrying data, %.1f MB, %d stalls (%.1f s waited), %d network changes" % (n["profile"], n["link"],
          s["reads"], s["hangs"], s["resets"], s["conversions"], s["refused"], s["extractions"], l["mb_s"] or "-", l["mb"],
          l["stalls"], l["stalled_s"], l["changes"]))'
}
# The runs of one platform, a line each: link, network, the phone network setting (- for none).
runs() {
  if [ $1 = tvos ]; then
    [ $TEST = testFilmOnThisLink ] && for link in ${=LINKS:-none far worst}; do echo "$link unmetered -"; done
    return
  fi
  for network in ${=NETWORK}; do
    if [ $network = unmetered ]; then
      for link in ${=LINKS:-none far worst}; do echo "$link unmetered -"; done
    else
      for link in ${=METERED_LINKS}; do for films in ${=PHONE_FILMS}; do echo "$link $network $films"; done; done
    fi
  done
}
hold() {
  until mkdir $1.lock 2>/dev/null; do echo "$1 in use by $(cat $1.lock/owner 2>/dev/null), waiting 60 s"; sleep 60; done
  echo $OWNER > $1.lock/owner
  held+=($1.lock)
}
build() {
  hold ${PRODUCTS[$1]}
  until mkdir $BUILD_LOCK 2>/dev/null; do echo "build lock held by $(cat $BUILD_LOCK/owner 2>/dev/null), waiting 60 s"; sleep 60; done
  echo $OWNER > $BUILD_LOCK/owner
  local errors=$(xcodebuild build-for-testing -scheme "${SCHEME[$1]}" -destination "platform=${OS[$1]} Simulator,id=${SIM[$1]}" \
    -derivedDataPath ${PRODUCTS[$1]} -quiet 2>&1 | grep -E "error:")
  rm -rf $BUILD_LOCK
  [ -z "$errors" ] || { echo "$errors" | head -5; echo "== ${OS[$1]} build failed: not run"; return 1; }
}
finish() {
  stop_proxy
  [ "$(cat $BUILD_LOCK/owner 2>/dev/null)" = $OWNER ] && rm -rf $BUILD_LOCK
  for lock in $held; do [ "$(cat $lock/owner 2>/dev/null)" = $OWNER ] && rm -rf $lock; done
  # Film bytes the relay kept fill a simulator's disk: each one used is erased.
  for platform in ${=PLATFORMS}; do xcrun simctl shutdown ${SIM[$platform]} 2>/dev/null; xcrun simctl erase ${SIM[$platform]} 2>/dev/null; done
  rm -rf $LOCK
}
[ $(free_mb) -ge 3500 ] || { echo "$(free_mb) MB free, a build needs 3500: not run"; exit 1; }
cd $APPLE
export TEST_RUNNER_TREE=$($APPLE/scripts/build-stamp.sh)
echo "$TEST_RUNNER_TREE $(date '+%H:%M') $TEST on $PLATFORMS"
until mkdir $LOCK 2>/dev/null; do echo "lock held by $(cat $LOCK/owner 2>/dev/null), waiting 60 s"; sleep 60; done
echo $OWNER > $LOCK/owner
trap finish EXIT INT TERM HUP
for platform in ${=PLATFORMS}; do
  sim=${SIM[$platform]}
  [ -n "$(runs $platform)" ] || { echo "== $platform: nothing to run ($TEST)"; continue; }
  [ $(free_mb) -ge 3500 ] || { echo "$(free_mb) MB free, a build needs 3500: $platform not run"; continue; }
  build $platform || continue
  built=$(/usr/libexec/PlistBuddy -c "Print :OpenreelBuild" ${PRODUCTS[$platform]}/Build/Products/${APP[$platform]}/Info.plist 2>/dev/null)
  echo "== $platform app build ${built:-without a stamp}$([ "$built" = "$TEST_RUNNER_TREE" ] && echo ', this tree' || echo ", not this tree ($TEST_RUNNER_TREE)"), in ${PRODUCTS[$platform]}"
  for run in "${(@f)$(runs $platform)}"; do
    parts=(${=run}); link=$parts[1] network=$parts[2] films=$parts[3]
    [ $(free_mb) -ge 1500 ] || { echo "$(free_mb) MB free: stopped before the $platform $link run"; exit 1; }
    tag="$platform $link $network$([ $films = - ] || echo " $films")"
    echo "== $tag $(date '+%H:%M'), $(free_mb) MB free$([ $TEST_RUNNER_LOW_DISK = 1 ] && echo ', the app reads it as low')"
    unset TEST_RUNNER_PROXY TEST_RUNNER_PROXY_PLAIN
    export TEST_RUNNER_NETWORK=$network TEST_RUNNER_PHONE_FILMS=$([ $films = - ] || echo $films)
    if [ $link != none ]; then
      python3 -u $APPLE/../scripts/throttle_proxy.py $PROXY_PORT $link > /tmp/openiptv/proxy-$PROXY_PORT.log 2>&1 &
      for _ in {1..20}; do lsof -t -iTCP:$PROXY_PORT -sTCP:LISTEN >/dev/null && break; sleep 0.5; done
      export TEST_RUNNER_PROXY=127.0.0.1:$PROXY_PORT
      # Plain HTTP carries the key in clear: through the proxy only for the test server.
      [ -n "${MOCK:-}" ] && export TEST_RUNNER_PROXY_PLAIN=1
    fi
    for attempt in 1 2 3; do
      for other in ${(v)SIM}; do xcrun simctl shutdown $other 2>/dev/null; done
      [ $attempt = 1 ] && xcrun simctl erase $sim 2>/dev/null
      xcrun simctl boot $sim 2>/dev/null; xcrun simctl bootstatus $sim -b >/dev/null 2>&1; sleep 5
      [ -n "${MOCK:-}" ] && far_end $link
      out=$(xcodebuild test-without-building -scheme "${SCHEME[$platform]}" -destination "platform=${OS[$platform]} Simulator,id=$sim" \
        -derivedDataPath ${PRODUCTS[$platform]} "-only-testing:${TARGET[$platform]}/RealFeedFilmTests/$TEST" 2>&1)
      if print -r -- "$out" | grep -q "Failed to get list of active applications"; then echo "(start-up error, attempt $attempt)"; continue; fi
      break
    done
    print -r -- "$out" | grep -E "REAL |error: -|Test Case .*(passed|failed|skipped)|Executed .* tests?," \
      | sed -E "s/^.*Test Case //; s/^.*(REAL )/\1/; s/^.*error: -/error: -/; s/ \([0-9.]+\) seconds$/ seconds/; s/^/[$tag] /" | uniq | head -80
    [ $link != none ] && { stop_proxy; sed "s/^/[$tag] /" /tmp/openiptv/proxy-$PROXY_PORT.log | tail -1; }
    [ -n "${MOCK:-}" ] && far_end_done | sed "s/^/[$tag] /"
  done
  xcrun simctl shutdown $sim 2>/dev/null
done
echo "== done $(date '+%H:%M')"
