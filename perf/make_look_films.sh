#!/bin/zsh
# make_look_films.sh [out-dir]: two minute films for perf/subtitle_look.py, each a mid-grey picture (no white in
# it) with one English subtitle line in the file, on screen from 1 s on: SDR 1080p (sdr-1080.mkv), SDR 720p
# (sdr-720.mkv), and HDR10 1080p (hdr10-1080.mkv: 10-bit HEVC, PQ, BT.2020, mastering data).
set -e
out=${1:-/tmp/openiptv/subs-look-media}
mkdir -p $out
printf '1\n00:00:01,000 --> 00:09:59,000\nSubtitle look HHHH 0123\n\n' > $out/look.srt
for size in 1920x1080 1280x720; do
  ffmpeg -v error -y -f lavfi -i "color=c=0x606060:size=${size}:rate=24000/1001,format=yuv420p" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -i $out/look.srt -t 120 -map 0:v -map 1:a -map 2:s -c:v libx264 -preset veryfast -crf 28 -g 24 -c:a aac -b:a 64k -c:s srt \
    -metadata:s:s:0 language=eng $out/sdr-${size#*x}.mkv
done
ffmpeg -v error -y -f lavfi -i "color=c=0x606060:size=1920x1080:rate=24000/1001,format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -i $out/look.srt -t 120 -map 0:v -map 1:a -map 2:s -c:v libx265 -preset ultrafast -crf 28 \
  -pix_fmt yuv420p10le -x265-params "log-level=error:hdr10=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
  -tag:v hvc1 -c:a aac -b:a 64k -c:s srt -metadata:s:s:0 language=eng $out/hdr10-1080.mkv
