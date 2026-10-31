#!/bin/zsh
# run.sh <script> <arg>...: perf/<script> run from a copy of perf/ and of the timing tests, made now, so
# edits to this tree while it runs reach neither it nor the commits it has yet to build.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
copy=/tmp/openiptv/perf-copy-$(basename $(dirname $HERE))-$(date +%H%M%S)
mkdir -p $copy/UITests-iOS $copy/UITests-tvOS && cp $HERE/*.sh $HERE/*.py $copy/
cp $HERE/../apple/UITests-iOS/{TimingCase,JumpTimingTests,StartTimingTests,SubtitleLookTests,LiveTimingTests}.swift $copy/UITests-iOS/ 2>/dev/null
cp $HERE/../apple/UITests-tvOS/JumpTimingTests.swift $copy/UITests-tvOS/
REPO=$(dirname $HERE) TESTS=$copy exec zsh $copy/$1 "${@:2}"
