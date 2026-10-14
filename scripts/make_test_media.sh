#!/usr/bin/env bash
# The UI tests' media, served by scripts/mock_server.py: a 10-minute test
# film (a moving test pattern with its time and frame number, and a tone),
# its HLS copy in 6 s segments (a server-converted stream), its preview
# thumbnails (Roku BIF, one every 10 s), and two 2-minute films with Spanish
# and English tracks (Spanish flagged default), one with English SDH
# subtitles too. Needs ffmpeg. Usage: make_test_media.sh <directory>
set -euo pipefail
out=${1:?usage: make_test_media.sh <directory>}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out/hls"
cd "$out"
ff() { ffmpeg -v error -y "$@"; }

ff -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=600" \
   -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=600" \
   -c:v libx264 -preset veryfast -g 60 -pix_fmt yuv420p -c:a aac -ac 1 test.mkv
ff -i test.mkv -c copy -f hls -hls_time 6 -hls_playlist_type vod \
   -hls_segment_filename "hls/seg%d.ts" hls/index.m3u8
python3 -I "$here/make_bif.py" test.mkv test.bif

printf '1\n00:00:01,000 --> 00:01:59,000\nENGLISH SUBTITLE\n' > eng.srt
printf '1\n00:00:01,000 --> 00:01:59,000\nSUBTITULO ESPANOL POR DEFECTO\n' > spa.srt
printf '1\n00:00:01,000 --> 00:01:59,000\n[MUSIC] ENGLISH SDH\n' > sdh.srt
two=(-f lavfi -i "testsrc2=size=1280x720:rate=30:duration=120"
     -f lavfi -i "sine=frequency=330:sample_rate=44100:duration=120"
     -f lavfi -i "sine=frequency=550:sample_rate=44100:duration=120")
codecs=(-c:v libx264 -preset veryfast -g 60 -pix_fmt yuv420p -c:a aac -ac 1 -c:s srt)
tracks=(-metadata:s:a:0 language=spa -metadata:s:a:1 language=eng -disposition:a:0 default -disposition:a:1 0
        -metadata:s:s:0 language=spa -metadata:s:s:1 language=eng -disposition:s:0 default -disposition:s:1 0)
ff "${two[@]}" -i spa.srt -i eng.srt -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s \
   "${codecs[@]}" "${tracks[@]}" multi.mkv
ff "${two[@]}" -i spa.srt -i eng.srt -i sdh.srt -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s -map 5:s \
   "${codecs[@]}" "${tracks[@]}" -metadata:s:s:2 language=eng -metadata:s:s:2 "title=English SDH" \
   -disposition:s:2 hearing_impaired multi-sdh.mkv
echo "test media in $out"
