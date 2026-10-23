#!/bin/zsh
# make_real_film.sh [out-dir]: a two-hour film for Continue Watching (about 510 MB).
# Keyframes are 24 frames apart at 24000/1001, as on a Blu-ray, so they fall
# between whole seconds. Minutes 3 to 10 are busy, so 8 MB there is about 7 s,
# which is where a resume lands. The rest is one colour so the file stays small.
# ffmpeg leaves the tags in the header. The rewrite moves them to after the
# index, where mkvmerge writes them.
#   OPENIPTV_MOCK_VIDEO=<out>/real.mkv and /mock/set?watched_elsewhere=m1 (3:36 in; the next card, an episode, 8:48 in)
set -e
out=${1:-/tmp/openreel-media/real}
mkdir -p $out
minute() {
  ffmpeg -v error -y -f lavfi -i "$2size=1280x720:rate=24000/1001" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 60 \
    -map 0:v -map 1:a -map 1:a -c:v libx264 -preset ultrafast -crf 23 -maxrate 8M -bufsize 8M -g 24 -keyint_min 24 \
    -sc_threshold 0 -pix_fmt yuv420p -c:a:0 ac3 -b:a:0 128k -ac:a:0 6 -c:a:1 aac -b:a:1 32k -ac:a:1 2 $out/$1.mkv
}
minute still "color=c=0x405060:"
minute busy "testsrc2="

{ for i in {1..120}; do echo "file '$out/$([ $i -gt 3 ] && [ $i -le 10 ] && echo busy || echo still).mkv'"; done } > $out/parts.txt
for lang in eng spa; do
  for k in {0..1799}; do
    printf '%d\n%02d:%02d:%02d,100 --> %02d:%02d:%02d,700\n%s %d\n\n' $((k + 1)) $(((3 + 4 * k) / 3600)) $(((3 + 4 * k) / 60 % 60)) \
      $(((3 + 4 * k) % 60)) $(((5 + 4 * k) / 3600)) $(((5 + 4 * k) / 60 % 60)) $(((5 + 4 * k) % 60)) $lang $k
  done > $out/$lang.srt
done
ffmpeg -v error -y -f concat -safe 0 -i $out/parts.txt -i $out/eng.srt -i $out/spa.srt -map 0 -map 1 -map 2 -c copy -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa -metadata:s:s:0 language=eng -metadata:s:s:1 language=spa $out/real.mkv
rm $out/still.mkv $out/busy.mkv $out/parts.txt
python3 -I "$(dirname $0)/mkv_tags_last.py" $out/real.mkv
rm $out/eng.srt $out/spa.srt
echo $out/real.mkv
