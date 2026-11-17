#!/bin/bash
set -euo pipefail
# Builds the sandboxed app exactly as it ships to the Mac App Store, signed by
# Xcode with the team's Apple Development certificate (team and bundle ID live
# in the project). -allowProvisioningUpdates lets Xcode create the certificate
# and register the bundle ID on a new machine.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-Release}"
case "$configuration" in Debug|Release) ;; *) printf '%s\n' 'Configuration must be Debug or Release.' >&2; exit 2 ;; esac

xcodebuild -project "$project_root/VoiceMacro.xcodeproj" -scheme VoiceMacro \
  -configuration "$configuration" -destination 'platform=macOS' \
  -derivedDataPath "$project_root/build/DerivedData" -allowProvisioningUpdates build
app="$project_root/build/DerivedData/Build/Products/$configuration/VoiceFn.app"
/usr/bin/codesign --verify --strict --deep "$app"
/usr/bin/codesign --display --entitlements - "$app"
printf '%s\n' "Built: $app"
