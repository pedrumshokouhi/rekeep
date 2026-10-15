#!/bin/zsh
# Archives, signs, and uploads Rekeep to App Store Connect (Mac and/or iOS).
#
#   ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-... scripts/release.sh [ios|mac|all]
#
# Needs an App Store Connect API key (.p8 in ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8)
# with App Manager (or Admin) access. Uploading does NOT submit for review; that is a separate step.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:?Set ASC_KEY_ID}"; : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%y%m%d%H%M)}"
OUT="$HOME/RekeepBuild/release/$BUILD_NUMBER"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
WHAT="${1:-all}"
mkdir -p "$OUT"

if [[ "$WHAT" == ios || "$WHAT" == all ]]; then
  echo "iOS: archiving build $BUILD_NUMBER…"
  xcodebuild -project Rekeep.xcodeproj -scheme RekeepMobile -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$OUT/Rekeep-iOS.xcarchive" archive CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${AUTH[@]}" > "$OUT/ios-archive.log" 2>&1
  xcodebuild -exportArchive -archivePath "$OUT/Rekeep-iOS.xcarchive" -exportOptionsPlist scripts/ExportOptions-iOS.plist \
    -exportPath "$OUT/ios" "${AUTH[@]}" > "$OUT/ios-export.log" 2>&1
  xcrun altool --upload-app -f "$OUT"/ios/*.ipa -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
fi

if [[ "$WHAT" == mac || "$WHAT" == all ]]; then
  echo "macOS: archiving build $BUILD_NUMBER…"
  xcodebuild -project Rekeep.xcodeproj -scheme Rekeep -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$OUT/Rekeep-macOS.xcarchive" archive CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${AUTH[@]}" > "$OUT/mac-archive.log" 2>&1
  xcodebuild -exportArchive -archivePath "$OUT/Rekeep-macOS.xcarchive" -exportOptionsPlist scripts/ExportOptions-macOS.plist \
    -exportPath "$OUT/mac" "${AUTH[@]}" > "$OUT/mac-export.log" 2>&1
  xcrun altool --upload-app -f "$OUT"/mac/*.pkg -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
fi
echo "Uploaded build $BUILD_NUMBER. Apple processes it in 5–30 minutes; then it appears in TestFlight."
