#!/bin/zsh
# make_net_film.sh [out-dir]: one film for measuring on a slow network (slow_link.py) and for
# Continue Watching, laid out like a real one (about 590 MB). 1080p at 24000/1001 with a
# keyframe every 24 frames, as on a Blu-ray, so keyframes fall between whole seconds. Where the
# tests play, it is busy at 16 Mbps, more than "far" and "worst" carry: 3:20 to 5:00 (a card at
# 3:36 played on for a minute) and 8:40 to 11:40 (an episode's card at 8:48, and the film after
# its jump of 5 minutes and back 30 s). The rest is one colour. English 5.1 AC-3 and Spanish
# stereo AAC, subtitles in both inside and an SDH file beside it. ffmpeg leaves the tags in the
# header; mkv_tags_last.py moves them after the index, as mkvmerge writes them.
#   OPENIPTV_MOCK_VIDEO=<out>/net.mkv OPENIPTV_MOCK_RUNTIME=900 OPENIPTV_MOCK_BITRATE=16000000
#   OPENIPTV_MOCK_SUBTITLE_FILES="eng|SDH|<out>/sdh.srt" and /mock/set?watched_elsewhere=m7 (3:36 in)
set -e
out=${1:-/tmp/openiptv/net-media}
mkdir -p $out
lines() {
  for k in {0..224}; do
    printf '%d\n00:%02d:%02d,100 --> 00:%02d:%02d,700\n%s %d\n\n' $((k + 1)) $((($3 + 4 * k) / 60)) $((($3 + 4 * k) % 60)) \
      $((($3 + 2 + 4 * k) / 60)) $((($3 + 2 + 4 * k) % 60)) $1 $k
  done > $out/$2.srt
}
lines EN eng 1
lines ES spa 1
lines SDH sdh 3
ffmpeg -v error -y -f lavfi -i "color=c=0x405060:size=1920x1080:rate=24000/1001" \
  -f lavfi -i "testsrc2=size=1920x1080:rate=24000/1001,noise=alls=40:allf=t" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -f lavfi -i "sine=frequency=660:sample_rate=48000" \
  -i $out/eng.srt -i $out/spa.srt -t 900 \
  -filter_complex "[0:v][1:v]overlay=enable='between(t,200,300)+between(t,520,700)'[v]" \
  -map "[v]" -map 2:a -map 3:a -map 4 -map 5 \
  -c:v libx264 -preset ultrafast -crf 18 -maxrate 16M -bufsize 16M -g 24 -keyint_min 24 -sc_threshold 0 -pix_fmt yuv420p \
  -c:a:0 ac3 -b:a:0 128k -ac:a:0 6 -c:a:1 aac -b:a:1 64k -ac:a:1 2 -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa -metadata:s:s:0 language=eng -metadata:s:s:1 language=spa \
  $out/net.mkv
python3 -I "$(dirname $0)/mkv_tags_last.py" $out/net.mkv
rm $out/eng.srt $out/spa.srt
echo $out/net.mkv
