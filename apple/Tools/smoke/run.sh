#!/usr/bin/env bash
# Build and run the provider smoke test (macOS). See main.swift for the
# environment variables it reads. `run.sh --build-only PATH` just builds.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
src=OpenIPTV
swiftc -O -target arm64-apple-macos14 -o "$out/smoke" \
  "$src/Model/Flex.swift" "$src/Model/Keychain.swift" "$src/Model/Sources.swift" \
  "$src/Live/LiveModels.swift" "$src/Live/XtreamProvider.swift" "$src/Live/M3UProvider.swift" \
  "$src/Live/StalkerProvider.swift" "$src/Live/Guide.swift" "$src/Live/LiveOrganizer.swift" \
  "$src/Emby/EmbyModels.swift" "$src/Emby/Artwork.swift" "$src/Emby/EmbyClient.swift" \
  "$src/Search/SearchIndex.swift" "$src/Search/IMDbRatings.swift" "$src/Search/SmartSearch.swift" "$src/Search/TMDbPopularity.swift" "$src/Search/Gzip.swift" "$src/Player/Trickplay.swift" \
  Tools/smoke/main.swift
if [[ "${1:-}" == "--build-only" ]]; then cp "$out/smoke" "${2:?path}"; exit 0; fi
"$out/smoke"
