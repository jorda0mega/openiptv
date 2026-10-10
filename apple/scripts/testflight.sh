#!/usr/bin/env bash
# Archive the iPhone/iPad and Apple TV apps and upload them to App Store
# Connect for TestFlight, signed with the Apple ID you're signed into in
# Xcode (Settings → Apple Accounts). No keys are written to disk.
#
#   apple/scripts/testflight.sh TEAMID            # both platforms
#   apple/scripts/testflight.sh TEAMID ios        # just one
set -euo pipefail
cd "$(dirname "$0")/.."
team=${1:?usage: testflight.sh TEAM_ID [ios|tvos]}
only=${2:-}
build=$(date +%Y%m%d%H%M)   # unique, increasing build number
[[ -d Vendor/Libmpv.xcframework ]] || scripts/fetch-mpvkit.sh
command -v xcodegen >/dev/null && xcodegen generate --quiet

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
options="$tmp/ExportOptions.plist"
cp ExportOptions.plist "$options"
/usr/libexec/PlistBuddy -c "Add :teamID string $team" "$options"

# Archive unsigned, then let export sign for App Store distribution: unlike
# a development-signed archive, that needs no registered devices (an Apple
# TV doesn't have to be in the developer account).
ship() { # scheme destination name
  local archive="build/archives/$3-$build.xcarchive"
  xcodebuild archive -project OpenIPTV.xcodeproj -scheme "$1" -destination "$2" \
    -archivePath "$archive" CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="$team" CURRENT_PROJECT_VERSION="$build" | tail -n 3
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
    -exportPath "build/export/$3-$build" -allowProvisioningUpdates | tail -n 3
  echo "uploaded $3 build $build"
}

[[ -z "$only" || "$only" == ios ]] && ship OpenIPTV "generic/platform=iOS" ios
[[ -z "$only" || "$only" == tvos ]] && ship "OpenIPTV TV" "generic/platform=tvOS" tvos
echo "Builds appear in App Store Connect → TestFlight after processing (usually 5–30 min)."
