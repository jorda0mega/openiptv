#!/usr/bin/env bash
# Build and run the provider smoke test (macOS). See main.swift for the
# environment variables it reads, and LiveProbe.swift for
# OPENIPTV_SMOKE_MODE=live-probe. `run.sh --build-only PATH` just builds.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
src=OpenIPTV
# The app's code needs macOS 26 (Flex.swift).
target=arm64-apple-macos26
# The app's version, for live-probe's user agent ("Openreel/<version>").
version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml | head -1)
printf 'extension LiveProbe { static let appVersion = "%s" }\n' "${version:-0}" > "$out/AppVersion.swift"
if [[ "${OPENIPTV_SMOKE_MODE:-}" == "live-probe" ]]; then
  # Only the Xtream login code: the full list below also needs app files
  # that use UIKit and libmpv, which do not build for the Mac.
  swiftc -O -target "$target" -o "$out/smoke" \
    "$src/Model/Flex.swift" "$src/Model/Keychain.swift" "$src/Model/Sources.swift" \
    "$src/Live/LiveModels.swift" "$src/Live/XtreamProvider.swift" "$src/Live/M3UProvider.swift" \
    "$src/Live/StalkerProvider.swift" Tools/smoke/LiveProbe.swift "$out/AppVersion.swift" Tools/smoke/live-probe/main.swift
else
  swiftc -O -target "$target" -o "$out/smoke" \
    "$src/Model/Flex.swift" "$src/Model/Keychain.swift" "$src/Model/Sources.swift" \
    "$src/Live/LiveModels.swift" "$src/Live/XtreamProvider.swift" "$src/Live/M3UProvider.swift" \
    "$src/Live/StalkerProvider.swift" "$src/Live/Guide.swift" "$src/Live/LiveOrganizer.swift" \
    "$src/Emby/EmbyModels.swift" "$src/Emby/Artwork.swift" "$src/Emby/EmbyClient.swift" \
    "$src/Search/SearchIndex.swift" "$src/Search/IMDbRatings.swift" "$src/Search/SmartSearch.swift" "$src/Search/TMDbPopularity.swift" "$src/Search/Gzip.swift" "$src/Player/Trickplay.swift" \
    Tools/smoke/LiveProbe.swift "$out/AppVersion.swift" Tools/smoke/main.swift
fi
if [[ "${1:-}" == "--build-only" ]]; then cp "$out/smoke" "${2:?path}"; exit 0; fi
"$out/smoke"
