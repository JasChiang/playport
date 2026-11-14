#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Turn an official Playport IPA into an iPhone Duo build: DuoHinge.dylib added and loaded,
# and the executable marked as built against the current SDK (else iOS runs it in a
# letterboxed compatibility window on the Duo). The result is ad hoc signed, ready for
# whatever you sideload with (Xcode, AltStore, SideStore, Sideloadly...), which re-signs it.
#
# Usage: duo/package.sh Playport-0.5.0.ipa [Playport-0.5.0-duo.ipa]
# Needs macOS with Xcode (an iOS 27.1+ SDK, for UIHingeInteraction) and python3.
set -euo pipefail

[ $# -ge 1 ] || { sed -n '3,9p' "$0"; exit 2; }
IPA="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="${2:-${IPA%.ipa}-duo.ipa}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
SDK_VERSION="${SDK_VERSION:-27.3}"
HERE="$(cd "$(dirname "$0")" && pwd)"

"$HERE/build.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK"
A="$WORK/Payload/Playport.app"
[ -f "$A/Playport" ] || { echo "not a Playport IPA: $IPA" >&2; exit 1; }

# The SDK the executable claims to be built with (minimum OS unchanged).
MINOS=$(otool -l "$A/Playport" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
xcrun vtool -set-build-version ios "$MINOS" "$SDK_VERSION" -replace -output "$A/Playport.new" "$A/Playport" 2>/dev/null
mv "$A/Playport.new" "$A/Playport"
plutil -replace DTPlatformVersion -string "$SDK_VERSION" "$A/Info.plist"
plutil -replace DTSDKName -string "iphoneos$SDK_VERSION" "$A/Info.plist"

# The dylib, loaded at launch.
mkdir -p "$A/Frameworks"
cp "$HERE/build/DuoHinge.dylib" "$A/Frameworks/"
python3 -I "$HERE/insert_dylib.py" "$A/Playport" "@executable_path/Frameworks/DuoHinge.dylib"

# Ad hoc, keeping the app's entitlements (Increased Memory Limit) for the sideloader to carry over.
codesign -f -s - "$A/Frameworks/DuoHinge.dylib"
codesign -f -s - --preserve-metadata=entitlements "$A"

rm -f "$OUT"
(cd "$WORK" && zip -qry "$OUT" Payload)
echo "wrote $OUT"
