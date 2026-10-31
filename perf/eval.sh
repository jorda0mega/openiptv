#!/bin/zsh
# eval.sh mock [profile] | real: the metric set on this tree's last commit, the iPhone first, then the Apple TV
# (and the iPad for Picture in Picture, which iPhone simulators lack), then a table against perf/best.json:
# each metric better, same or REGRESSION by the run's own spread (perf/perf.py compare).
#   mock: the test server under the profile (worst unless given): starts, ±10 s and 5 minute jumps (timed to the
#     picture from a screen recording), subtitle look (SDR 720p and HDR10 films), live start and switches; on
#     the Apple TV, jumps; on the iPad, Picture in Picture's gaps.
#   real: the real feeds through the logins helper at FEED (http://127.0.0.1:8799 unless set): starts and
#     jumps on the iPhone, jumps on the Apple TV. The logins stay in the helper; the app reports nothing to
#     the server; nothing here prints an address (the output ends with its url-like count, which must be 0).
# Commit first: each run builds the commit, not the working tree. ONLY="starts jumps look live pip" picks
# parts; PLATFORMS="ios tvos ipad" picks platforms. Runs through perf/run.sh, from a copy.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd $HERE/.. && pwd)
mode=${1:-mock}
commit=$(git -C $REPO rev-parse --short HEAD)
stamp=$(date +%m%d-%H%M)
OUT=/tmp/openiptv/perf-evals/$mode-$stamp
mkdir -p $OUT
ONLY=${ONLY:-starts jumps look live pip}
PLATFORMS=${PLATFORMS:-ios tvos ipad}
wants() { [[ " $ONLY " == *" $1 "* && " $PLATFORMS " == *" $2 "* ]]; }
# Every printed line is kept in out.txt too: the url-like count at the end reads all of it.
run() { OUT=$OUT zsh $HERE/run.sh sim_runs.sh "$@" $commit 2>&1 | tee -a $OUT/out.txt; }
media=/tmp/openiptv/subs-look-media
if [ $mode = real ]; then
  export FEED=${FEED:-http://127.0.0.1:8799}
  # A worktree of its own: a test server bisect may be using the shared one.
  export WT=/tmp/openiptv/wt-real-$(basename $REPO)
  # The real runs build into their own folders, which no helper builds into.
  curl -sf -o /dev/null $FEED/emby 2>/dev/null || { echo "the logins helper isn't running"; exit 1; }
  echo "== real feeds, commit $commit, $(date '+%a %H:%M')"
  wants starts ios && PLATFORM=ios LIMIT=2400 run StartTimingTests/testStarts
  wants jumps ios && PLATFORM=ios run JumpTimingTests/testTenSecondJumps
  wants jumps tvos && PLATFORM=tvos run JumpTimingTests/testTenSecondJumps
else
  profile=${2:-worst}
  [ -f /tmp/openiptv/jump-media/jump.mkv ] || zsh $HERE/make_jump_film.sh
  [ -f $media/hdr10-1080.mkv ] || zsh $HERE/make_look_films.sh $media
  echo "== test server $profile, commit $commit, $(date '+%a %H:%M')"
  export PROFILE=$profile
  # Continue Watching: m7 first (3:36 in), the episode 2 minutes in (the test server's 10 minutes is past the film's end).
  cards="watched_elsewhere=m7&episode_resume=120"
  wants starts ios && PLATFORM=ios SET=$cards LIMIT=2400 run StartTimingTests/testStarts
  wants jumps ios && PLATFORM=ios run JumpTimingTests/testTenSecondJumps
  wants look ios && PLATFORM=ios PROFILE=none TAG=sdr720 FILM=$media/sdr-720.mkv run SubtitleLookTests/testSubtitleLook
  wants look ios && PLATFORM=ios PROFILE=none TAG=hdr10 FILM=$media/hdr10-1080.mkv run SubtitleLookTests/testSubtitleLook
  wants live ios && PLATFORM=ios run LiveTimingTests/testLiveStartAndSwitch
  wants jumps tvos && PLATFORM=tvos SET=$cards run JumpTimingTests/testTenSecondJumps
  wants pip ipad && PLATFORM=ipad PROFILE=none run PlayerLookTests/testOpeningTheAppBringsTheFilmBackInline
fi
# Subtitle look and Picture in Picture run on the test server's own profile-free link: they compare against
# the best for mock:none, the rest against the best for this run's target.
echo "== against perf/best.json"
setopt null_glob
samples=($OUT/*/*/samples.jsonl)
[ ${#samples} -gt 0 ] && PLATFORMS="$PLATFORMS" python3 -I $HERE/perf.py compare $samples | tee $OUT/table.txt || echo "no samples" | tee $OUT/table.txt
echo "lines $(cat $OUT/out.txt $OUT/table.txt 2>/dev/null | wc -l | tr -d ' '), url-like $(cat $OUT/out.txt $OUT/table.txt 2>/dev/null | grep -cE '://|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|\.(com|net|org|tv|me|io)\b')"
echo "== eval done $(date '+%H:%M'), results in $OUT"
