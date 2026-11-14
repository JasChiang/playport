#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build duo/build/DuoHinge.dylib for iOS arm64 (needs an iOS 27.1+ SDK for UIHingeInteraction).
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
grep -rqs "UIHingeInteraction" "$SDK/System/Library/Frameworks/UIKit.framework/Headers" \
    || { echo "this SDK has no UIHingeInteraction: use Xcode with iOS 27.1+ (set DEVELOPER_DIR)" >&2; exit 1; }
mkdir -p build
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=26.0 \
    -dynamiclib -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
    -install_name @executable_path/Frameworks/DuoHinge.dylib \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
    DuoHinge.m -o build/DuoHinge.dylib
echo "built $(pwd)/build/DuoHinge.dylib"
