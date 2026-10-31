#!/bin/bash
# Builds, signs, notarizes and staples nTails.app, zipped into dist/.
# Usage: nTails/build-release.sh <version>   (e.g. v0.3.0)
#
# Environment:
#   NOTARY_PROFILE   notarytool keychain profile       (default: ntails-notary)
#   NOTARY_KEYCHAIN  keychain file holding that profile (default: login keychain)
#   SKIP_NOTARIZE=1  sign only, do not submit to Apple
set -euo pipefail

tag=$1
version=${tag#v}
version=${version%%-*}
cd "$(dirname "$0")"

TEAM_ID=7MAQ6Y7MWC
APP_CERT="Developer ID Application: Dylan Hardison ($TEAM_ID)"
NOTARY_PROFILE=${NOTARY_PROFILE:-ntails-notary}
dist=$PWD/../dist
archive=build/nTails.xcarchive
app=$archive/Products/Applications/nTails.app
zip=$dist/nTails-$tag-macos-universal.zip

security find-identity -v -p codesigning | grep -qF "\"$APP_CERT\"" ||
	{
		echo "error: no signing identity: $APP_CERT" >&2
		exit 1
	}

# `xcodebuild build` injects the get-task-allow debug entitlement, which
# notarization rejects; `archive` does not.
rm -rf build
GO_BIN="${GO_BIN:-$(command -v go)}" NTAILSD_VERSION=$tag xcodebuild archive -quiet \
	-project nTails.xcodeproj -scheme nTails -configuration Release \
	-destination platform=macOS -derivedDataPath build -archivePath "$archive" \
	ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$version" \
	CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$TEAM_ID \
	CODE_SIGN_IDENTITY="$APP_CERT" OTHER_CODE_SIGN_FLAGS=--timestamp
codesign --verify --strict --deep --verbose=2 "$app"

mkdir -p "$dist"
ditto -c -k --keepParent "$app" "$zip"

if [ "${SKIP_NOTARIZE:-0}" = 1 ]; then
	echo "SKIP_NOTARIZE set; app is signed but not notarized." >&2
else
	keychain=()
	[ -n "${NOTARY_KEYCHAIN:-}" ] && keychain=(--keychain "$NOTARY_KEYCHAIN")
	xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" \
		${keychain[@]+"${keychain[@]}"} --wait
	# The ticket is stapled into the bundle, so the zip is rebuilt afterwards.
	xcrun stapler staple "$app"
	ditto -c -k --keepParent "$app" "$zip"
	spctl --assess --type execute -vv "$app"
fi
echo "Done: $zip"
