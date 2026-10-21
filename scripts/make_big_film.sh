#!/bin/zsh
# make_big_film.sh [out-dir]: a four-minute 16 Mbps test film (about 490 MB, 2 MB a
# second, half what a 4K film reads) with sound in English and Spanish and
# subtitles inside it in both, a line a second ("EN 12", "ES 12" from 12 s). For
# PlayerLookTests/testSubtitlesPickedLateInAFilmReadNothingAgain:
#   OPENIPTV_MOCK_VIDEO=<out>/big.mkv OPENIPTV_MOCK_RUNTIME=240 TEST_RUNNER_BIG_FILM=1
set -e
out=${1:-/tmp/openreel-media/big}
mkdir -p $out
lines() {
  for i in {0..239}; do
    printf '%d\n00:%02d:%02d,000 --> 00:%02d:%02d,900\n%s %d\n\n' $((i + 1)) $((i / 60)) $((i % 60)) $((i / 60)) $((i % 60)) $1 $i
  done > $out/$2.srt
}
lines EN eng
lines ES spa
ffmpeg -v error -y -f lavfi -i "testsrc2=size=1920x1080:rate=24,noise=alls=40:allf=t" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -f lavfi -i "sine=frequency=660:sample_rate=48000" \
  -i $out/spa.srt -i $out/eng.srt -t 240 -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s \
  -c:v libx264 -preset ultrafast -b:v 16M -minrate 16M -maxrate 16M -bufsize 16M -x264-params nal-hrd=cbr -g 48 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -c:s srt -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa \
  -metadata:s:s:0 language=spa -metadata:s:s:1 language=eng $out/big.mkv
rm $out/eng.srt $out/spa.srt
echo $out/big.mkv
