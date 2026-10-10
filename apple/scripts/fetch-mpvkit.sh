#!/usr/bin/env bash
# Download the LGPL MPVKit xcframeworks listed in mpvkit.lock into Vendor/,
# verifying each archive's SHA-256. Run from anywhere; safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Vendor .downloads
while read -r name url sum; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ -d "Vendor/$name.xcframework" ]] && continue
  zip=".downloads/$name.zip"
  curl -sfL --retry 3 -o "$zip" "$url"
  echo "$sum  $zip" | shasum -a 256 -c --quiet -
  rm -rf "Vendor/$name.xcframework"
  unzip -q -o "$zip" -d Vendor
  echo "fetched $name"
done < mpvkit.lock
rm -rf .downloads
