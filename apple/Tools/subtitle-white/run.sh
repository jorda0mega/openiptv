#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ -d Vendor/Libmpv.xcframework ]] || scripts/fetch-mpvkit.sh
here=Tools/subtitle-white
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir "$out/fw" "$out/media"
for slice in Vendor/*.xcframework/macos-*; do ln -sf "$PWD/$slice"/* "$out/fw/"; done
frameworks=()
for f in "$out"/fw/*.framework; do frameworks+=(-framework "$(basename "$f" .framework)"); done
clang -c "$here/lua.c" -o "$out/lua.o"
swiftc -O -target arm64-apple-macos26 -F "$out/fw" -Xcc -F"$out/fw" OpenIPTV/Player/FramePlan.swift "$here/main.swift" "$out/lua.o" \
  -o "$out/subtitle-white" "${frameworks[@]}" -L"$out/fw" -lMoltenVK -framework AVFoundation -framework AudioToolbox \
  -framework CoreAudio -framework CoreImage -framework CoreMedia -framework CoreVideo -framework Metal -framework QuartzCore \
  -framework VideoToolbox -framework IOSurface -framework IOKit -framework Cocoa -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++

m=$out/media
printf '1\n00:00:00,500 --> 00:00:59,000\nSubtitle look HHHH 0123\n\n' > "$m/text.srt"
printf '1\n00:00:00,500 --> 00:00:59,000\n<font color="#ffffff">Tagged HHHH 0123</font>\n\n' > "$m/tagged.srt"
printf 'WEBVTT\n\n00:00:00.500 --> 00:00:59.000\nWebVTT HHHH 0123\n' > "$m/text.vtt"
printf '%s\n' '[Script Info]' 'ScriptType: v4.00+' 'PlayResX: 1920' 'PlayResY: 1080' 'YCbCr Matrix: None' '' '[V4+ Styles]' \
  'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding' \
  'Style: Default,Arial,64,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,60,1' '' '[Events]' \
  'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text' \
  'Dialogue: 0,0:00:00.50,0:00:59.00,Default,,0,0,0,,Styled HHHH 0123' > "$m/styled.ass"
python3 -I "$here/make_sup.py" "$m/picture.sup"
for film in "hdr10 smpte2084" "hlg arib-std-b67" "sdr bt709"; do
  name=${film% *} transfer=${film#* }
  if [[ $name == sdr ]]; then
    ffmpeg -v error -f lavfi -i "color=c=0x606060:size=1920x1080:rate=24,format=yuv420p" -t 2 -c:v libx264 -preset ultrafast "$m/$name.mkv"
  else
    ffmpeg -v error -f lavfi -i "color=c=0x606060:size=1920x1080:rate=24,format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=$transfer:colorspace=bt2020nc" \
      -t 2 -c:v libx265 -preset ultrafast -x265-params "log-level=error:colorprim=bt2020:transfer=$transfer:colormatrix=bt2020nc" "$m/$name.mkv"
  fi
  ffmpeg -v error -i "$m/$name.mkv" -i "$m/picture.sup" -map 0:v -map 1:s -c copy "$m/$name-pgs.mkv"
  ffmpeg -v error -i "$m/$name.mkv" -i "$m/text.srt" -map 0:v -map 1:s -c:v copy -c:s mov_text "$m/$name-mov_text.mp4"
done
DYLD_FRAMEWORK_PATH="$out/fw" "$out/subtitle-white" "$m"
