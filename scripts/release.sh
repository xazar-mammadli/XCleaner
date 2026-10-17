#!/bin/zsh
# Builds a release of XCleaner: the app signed with the maintainer's identity, in a disk image, with its SHA-256.
#
#   scripts/release.sh 1.0.0
#
# The version must match MARKETING_VERSION in the Xcode project. Signing uses the identity made by
# make-signing-identity.sh; without it, the build is signed for this Mac only and the script stops before packaging.
set -euo pipefail

version=${1:?"usage: scripts/release.sh <version>"}
root=${0:A:h:h}
output="$root/.build/release"
keychain=${SIGNING_KEYCHAIN:-$HOME/Library/Keychains/self-signed-codesign.keychain-db}
password_file=${keychain%.keychain-db}.password

if [[ ! -e $keychain || ! -e $password_file ]]; then
    echo "No signing identity at $keychain. Run scripts/make-signing-identity.sh first." >&2
    exit 1
fi

rm -rf "$output"
mkdir -p "$output"

echo "Building $version…"
xcodebuild -project "$root/XCleaner.xcodeproj" -scheme XCleaner -configuration Release -derivedDataPath "$output/DerivedData" \
    -destination "generic/platform=macOS" build -quiet
app="$output/DerivedData/Build/Products/Release/XCleaner.app"
built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
if [[ $built != "$version" ]]; then
    echo "The project builds version $built, not $version. Update MARKETING_VERSION first." >&2
    exit 1
fi

echo "Signing…"
security unlock-keychain -p "$(<"$password_file")" "$keychain"
# codesign finds the identity only through the search list. It is added for the signing and taken out again.
original=("${(@f)$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')}")
trap 'security list-keychains -d user -s "${original[@]}"' EXIT
security list-keychains -d user -s "${original[@]}" "$keychain"
identity=$(security find-identity -p codesigning "$keychain" | awk '/1\)/ {print $2; exit}')
# A fresh signature: the hardened runtime as Xcode set it, and none of the debugging entitlements of a local build.
codesign --force --sign "$identity" --options runtime --timestamp=none "$app"
codesign --verify --strict --verbose=2 "$app"

echo "Packaging…"
staging="$output/image"
mkdir -p "$staging"
ditto "$app" "$staging/XCleaner.app"
ln -s /Applications "$staging/Applications"
image="$output/XCleaner-$version.dmg"
hdiutil create -quiet -volname "XCleaner $version" -srcfolder "$staging" -format UDZO -ov "$image"
codesign --force --sign "$identity" --timestamp=none "$image"
(cd "$output" && shasum -a 256 "XCleaner-$version.dmg" > "XCleaner-$version.dmg.sha256")

echo "Done:"
echo "  $image"
echo "  $image.sha256"
codesign -d -r- "$app" 2>&1 | tail -1
