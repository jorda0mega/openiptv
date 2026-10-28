#!/usr/bin/env bash
# Fails when the player passes libmpv an option or property name it does not know, or a literal value it refuses.
# Sub-keys and track fields are read on a short test film. With MPV_NAMES_PAIRS=stdin, data pairs come on stdin
# (MacTests/MPVNamesTests).
# On the Mac; needs ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
Tools/libmpv-mac.sh "$out/mpv-names" Tools/mpv-names/main.swift
printf '1\n00:00:00,000 --> 00:00:09,000\nLine\n\n' > "$out/line.srt"
ffmpeg -nostdin -v error -f lavfi -i testsrc=size=320x240:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 -i "$out/line.srt" -t 2 \
  -map 0:v -map 1:a -map 2:s -c:v mpeg4 -c:a aac -c:s srt -metadata:s:a:0 language=eng -metadata:s:a:0 title=Main \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title=English -metadata:s:v:0 title=Picture "$out/film.mkv"
"$out/mpv-names" "$out/film.mkv" $(find OpenIPTV -name '*.swift')
