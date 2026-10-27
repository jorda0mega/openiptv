#!/bin/zsh
# run.sh <script> <arg>...: perf/<script> run from a copy of perf/ and of the timing tests, made now, so
# edits to this tree while it runs reach neither it nor the commits it has yet to build.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
copy=/tmp/openiptv/perf-copy-$(basename $(dirname $HERE))-$(date +%H%M%S)
mkdir -p $copy && cp $HERE/*.sh $HERE/*.py $HERE/../apple/UITests-iOS/{JumpTimingTests,StartTimingTests,SubtitleLookTests}.swift $copy/
REPO=$(dirname $HERE) TESTS=$copy exec zsh $copy/$1 "${@:2}"
