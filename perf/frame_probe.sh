#!/bin/zsh
# frame_probe.sh FILM SECONDS WIDTHxHEIGHT...: perf/frame_probe.swift, built once against the macOS slice of the
# app's MPVKit frameworks (FW: livebench's folder of them unless set), run on the Mac (no simulator).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
FW=${FW:-/tmp/openiptv/livebench/fw}
BIN=/tmp/openiptv/frame-probe
if [ ! -x $BIN ] || [ $HERE/frame_probe.swift -nt $BIN ]; then
  fws=(); for f in $FW/*.framework; do fws+=(-framework $(basename $f .framework)); done
  # luastub.o: empty Lua symbols (MPVKit links Lua scripting, which the probe never loads).
  swiftc -O -target arm64-apple-macos14 -F $FW -Xcc -F$FW $HERE/frame_probe.swift ${LUASTUB:-/tmp/openiptv/livebench/luastub.o} -o $BIN $fws -L$FW -lMoltenVK \
    -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework CoreMedia -framework CoreVideo \
    -framework Metal -framework QuartzCore -framework VideoToolbox -framework IOSurface -framework IOKit -framework Cocoa \
    -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++
fi
DYLD_FRAMEWORK_PATH=$FW $BIN "$@"
