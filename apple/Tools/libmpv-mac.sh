#!/usr/bin/env bash
# libmpv-mac.sh OUT SWIFT...: a Mac program built against the macOS slice of the app's MPVKit frameworks.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d Vendor/Libmpv.xcframework ]] || scripts/fetch-mpvkit.sh
out=$1
shift
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/fw"
for slice in Vendor/*.xcframework/macos-*; do ln -sf "$PWD/$slice"/* "$work/fw/"; done
frameworks=()
for f in "$work"/fw/*.framework; do frameworks+=(-framework "$(basename "$f" .framework)"); done
clang -c Tools/lua.c -o "$work/lua.o"
swiftc -O -target arm64-apple-macos26 -F "$work/fw" -Xcc -F"$work/fw" "$@" "$work/lua.o" -o "$out" "${frameworks[@]}" -L"$work/fw" -lMoltenVK \
  -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework CoreImage -framework CoreMedia -framework CoreVideo \
  -framework Metal -framework QuartzCore -framework VideoToolbox -framework IOSurface -framework IOKit -framework Cocoa \
  -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++
