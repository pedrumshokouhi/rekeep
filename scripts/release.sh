#!/bin/zsh
# Archives and signs Rekeep for App Store Connect (Mac and/or iOS).
#
#   scripts/release.sh [ios|mac|all]                         (uses the Apple account signed in to Xcode)
#   ASC_KEY_ID=… ASC_ISSUER_ID=… scripts/release.sh [ios|mac|all]  (also uploads with an App Store Connect API key)
#
# The team has no registered devices, so development profiles can't be made and a normal signed
# archive fails. Instead: archive unsigned, sign each bundle (inner first) with the Apple Distribution
# identity and its entitlements file, and stamp the team into the archive. That keeps the App Group
# entitlement through export. Without an API key, the archives are copied into Xcode's Organizer;
# upload them there with Distribute App › App Store Connect (xcodebuild's account upload is broken
# with "Actor/relationships/providerId").
#
# Uploading does NOT submit for review; that is a separate step in App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%y%m%d%H%M)}"
OUT="$HOME/RekeepBuild/release/$BUILD_NUMBER"
TEAM=RMZ2B524CF
IDENTITY="Apple Distribution: Pedrum Shokouhi ($TEAM)"
ORGANIZER="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
WHAT="${1:-all}"
mkdir -p "$OUT" "$ORGANIZER"

# sign_and_stamp <archive> <bundle-relative-path> <entitlements> [extra codesign flags…]; call inner bundles first.
sign() { local arc="$1" rel="$2" ent="$3"; shift 3
  codesign -f -s "$IDENTITY" --entitlements "$ent" "$@" "$arc/Products/Applications/$rel"; }
stamp() {
  /usr/libexec/PlistBuddy -c "Set :ApplicationProperties:Team $TEAM" \
    -c "Set :ApplicationProperties:SigningIdentity '$IDENTITY'" "$1/Info.plist"
}
ship() { # <archive> <platform> <ExportOptions> <artifact glob>
  if [[ -n "${ASC_KEY_ID:-}" ]]; then
    local key="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
    xcodebuild -exportArchive -archivePath "$1" -exportOptionsPlist "scripts/ExportOptions-$3.plist" -exportPath "$OUT/$2" \
      -allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ASC_ISSUER_ID" > "$OUT/$2-export.log" 2>&1
    xcrun altool --upload-app -f "$OUT"/$2/$4 -t "$2" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  else
    cp -R "$1" "$ORGANIZER/$(basename "$1" .xcarchive) $BUILD_NUMBER.xcarchive"
    echo "  → in Xcode Organizer; upload with Distribute App › App Store Connect."
  fi
}

if [[ "$WHAT" == ios || "$WHAT" == all ]]; then
  echo "iOS: archiving build $BUILD_NUMBER…"
  ARC="$OUT/Rekeep-iOS.xcarchive"
  xcodebuild -project Rekeep.xcodeproj -scheme RekeepMobile -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARC" archive CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGNING_ALLOWED=NO > "$OUT/ios-archive.log" 2>&1
  sign "$ARC" Rekeep.app/PlugIns/RekeepKeyboard.appex iOS/Keyboard/RekeepKeyboard.entitlements
  sign "$ARC" Rekeep.app/PlugIns/RekeepShare.appex iOS/Share/RekeepShare.entitlements
  sign "$ARC" Rekeep.app iOS/App/Rekeep.entitlements
  stamp "$ARC"
  ship "$ARC" ios iOS "*.ipa"
fi

if [[ "$WHAT" == mac || "$WHAT" == all ]]; then
  echo "macOS: archiving build $BUILD_NUMBER…"
  ARC="$OUT/Rekeep-macOS.xcarchive"
  xcodebuild -project Rekeep.xcodeproj -scheme Rekeep -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARC" archive CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGNING_ALLOWED=NO > "$OUT/mac-archive.log" 2>&1
  sign "$ARC" Rekeep.app Mac/Rekeep.entitlements -o runtime
  stamp "$ARC"
  ship "$ARC" macos macOS "*.pkg"
fi
echo "Build $BUILD_NUMBER ready. After upload, Apple processes it in 5–30 minutes; then it appears in TestFlight."
