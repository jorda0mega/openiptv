#!/bin/zsh
# make_open_film.sh [out-dir]: a film that opens as the real server's films did (about 230 MB). Its
# header runs past the player's first read of 512 KB (a font attached, as real files carry fonts and
# cover art), so a start reads 0.52 MB at 0%, then 8.4 MB just after it, then the end (the index, then
# the tags, where mkvmerge writes them), then where it plays. 15 minutes of 1080p at 24000/1001 with a
# keyframe every 24 frames, busy at 16 Mbps from 3:20 to 5:00 (a card 3:36 in plays on there) and one
# colour elsewhere. English 5.1 AC-3, Spanish stereo AAC and an English commentary in stereo AAC.
# Subtitles inside: English, a line every 4 s, and Spanish, sparse: a line every 75 s.
#   FILM=open zsh scripts/mock_film_run.sh <profile> <out.txt>
set -e
out=${1:-/tmp/openiptv/net-media}
font=/System/Library/Fonts/Supplemental/Arial.ttf
mkdir -p $out
lines() {
  for k in {0..$((899 / $3 - 1))}; do
    local at=$(($4 + $3 * k))
    printf '%d\n00:%02d:%02d,100 --> 00:%02d:%02d,700\n%s %d\n\n' $((k + 1)) $((at / 60)) $((at % 60)) \
      $(((at + 2) / 60)) $(((at + 2) % 60)) $1 $k
  done > $out/open-$2.srt
}
lines EN eng 4 1
lines ES spa 75 30
ffmpeg -v error -y -f lavfi -i "color=c=0x405060:size=1920x1080:rate=24000/1001" \
  -f lavfi -i "testsrc2=size=1920x1080:rate=24000/1001,noise=alls=40:allf=t" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -f lavfi -i "sine=frequency=660:sample_rate=48000" \
  -f lavfi -i "sine=frequency=550:sample_rate=48000" -i $out/open-eng.srt -i $out/open-spa.srt -t 900 \
  -filter_complex "[0:v][1:v]overlay=enable='between(t,200,300)'[v]" \
  -map "[v]" -map 2:a -map 3:a -map 4:a -map 5 -map 6 \
  -c:v libx264 -preset ultrafast -crf 18 -maxrate 16M -bufsize 16M -g 24 -keyint_min 24 -sc_threshold 0 -pix_fmt yuv420p \
  -c:a:0 ac3 -b:a:0 128k -ac:a:0 6 -c:a:1 aac -b:a:1 64k -ac:a:1 2 -c:a:2 aac -b:a:2 64k -ac:a:2 2 -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa -metadata:s:a:2 language=eng -metadata:s:a:2 title=Commentary \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=spa \
  -attach $font -metadata:s:t:0 mimetype=application/x-truetype-font \
  $out/open.mkv
python3 -I "$(dirname $0)/mkv_tags_last.py" $out/open.mkv
rm $out/open-eng.srt $out/open-spa.srt
echo $out/open.mkv
