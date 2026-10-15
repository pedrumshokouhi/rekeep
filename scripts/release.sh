#!/bin/zsh
# Archives, signs, and uploads Rekeep to App Store Connect (Mac and/or iOS).
#
#   scripts/release.sh [ios|mac|all]                         (uses the Apple account signed in to Xcode)
#   ASC_KEY_ID=… ASC_ISSUER_ID=… scripts/release.sh [ios|mac|all]  (uses an App Store Connect API key)
#
# Uploading does NOT submit for review; that is a separate step in App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%y%m%d%H%M)}"
OUT="$HOME/RekeepBuild/release/$BUILD_NUMBER"
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
else
  AUTH=(-allowProvisioningUpdates)   # Xcode › Settings › Accounts must be signed in
fi
WHAT="${1:-all}"
# With an Xcode account, export straight to App Store Connect (destination=upload).
opts() {
  local src="scripts/ExportOptions-$1.plist"
  if [[ -n "${ASC_KEY_ID:-}" ]]; then echo "$src"; return; fi
  local tmp="$OUT/ExportOptions-$1-upload.plist"
  cp "$src" "$tmp"; /usr/libexec/PlistBuddy -c "Add :destination string upload" "$tmp" >/dev/null
  echo "$tmp"
}
mkdir -p "$OUT"

if [[ "$WHAT" == ios || "$WHAT" == all ]]; then
  echo "iOS: archiving build $BUILD_NUMBER…"
  xcodebuild -project Rekeep.xcodeproj -scheme RekeepMobile -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$OUT/Rekeep-iOS.xcarchive" archive CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${AUTH[@]}" > "$OUT/ios-archive.log" 2>&1
  xcodebuild -exportArchive -archivePath "$OUT/Rekeep-iOS.xcarchive" -exportOptionsPlist "$(opts iOS)" \
    -exportPath "$OUT/ios" "${AUTH[@]}" > "$OUT/ios-export.log" 2>&1
  if [[ -n "${ASC_KEY_ID:-}" ]]; then xcrun altool --upload-app -f "$OUT"/ios/*.ipa -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"; fi
fi

if [[ "$WHAT" == mac || "$WHAT" == all ]]; then
  echo "macOS: archiving build $BUILD_NUMBER…"
  xcodebuild -project Rekeep.xcodeproj -scheme Rekeep -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$OUT/Rekeep-macOS.xcarchive" archive CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${AUTH[@]}" > "$OUT/mac-archive.log" 2>&1
  xcodebuild -exportArchive -archivePath "$OUT/Rekeep-macOS.xcarchive" -exportOptionsPlist "$(opts macOS)" \
    -exportPath "$OUT/mac" "${AUTH[@]}" > "$OUT/mac-export.log" 2>&1
  if [[ -n "${ASC_KEY_ID:-}" ]]; then xcrun altool --upload-app -f "$OUT"/mac/*.pkg -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"; fi
fi
echo "Uploaded build $BUILD_NUMBER. Apple processes it in 5–30 minutes; then it appears in TestFlight."
