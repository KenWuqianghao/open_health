#!/bin/bash
# Package the device + simulator libtorch builds into xcframeworks, wrapping each dylib
# in a proper .framework bundle — the App Store rejects bare embedded .dylib files
# (ITMS-90426 "SwiftSupport folder is missing" / invalid bundle), it wants dynamic libs
# inside frameworks. Xcode then picks the right slice per SDK and embeds+signs them.
#
# Prereq: the device slice; the simulator slice is optional (device-only xcframeworks
# build and archive for a phone, the simulator needs the second slice) —
#   apps/ios/spike/build_libtorch_ios.sh device   # device    → build_ios_device/install
#   apps/ios/spike/build_libtorch_ios.sh          # simulator → build_ios/install
#
# Output: apps/ios/libtorch-xcframeworks/<name>.xcframework plus include/ (gitignored).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"   # repo root from this script's location
LT="$REPO/local/libtorch-ios/pytorch"
SIM="$LT/build_ios/install/lib"
DEV="$LT/build_ios_device/install/lib"
OUT="$REPO/apps/ios/libtorch-xcframeworks"
WORK="$REPO/apps/ios/.libtorch-frameworks-build"
MIN=17.0
LIBS="libtorch libtorch_cpu libc10 libtorch_global_deps"

[ -d "$DEV" ] || { echo "missing $DEV — build the device slice first"; exit 1; }
HAVE_SIM=1
[ -d "$SIM" ] || { HAVE_SIM=0; echo "note: no simulator slice at $SIM — packaging device-only xcframeworks"; }

# Wrap one dylib in a flat iOS .framework: binary named after the framework, install
# name @rpath/<name>.framework/<name>, inter-lib deps rewritten to the framework paths,
# minos normalized, and a minimal Info.plist. $4 = iPhoneOS | iPhoneSimulator, $5 = vtool
# platform (2 device / 7 simulator).
make_framework() {
    local src="$1" name="$2" outdir="$3" plat="$4" vtoolplat="$5"
    local fw="$outdir/$name.framework"
    rm -rf "$fw"; mkdir -p "$fw"
    cp "$src" "$fw/$name"
    vtool -set-build-version "$vtoolplat" "$MIN" "$MIN" -replace -output "$fw/$name" "$fw/$name" >/dev/null
    install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name"
    for dep in $LIBS; do
        install_name_tool -change "@rpath/$dep.dylib" "@rpath/$dep.framework/$dep" "$fw/$name" 2>/dev/null || true
    done
    # a dSYM with the binary's UUID so archives ship symbols for these prebuilt
    # frameworks (otherwise App Store reports "Upload Symbols Failed"). No DWARF in the
    # binaries, but the UUID match is what the symbol-upload step checks.
    dsymutil "$fw/$name" -o "$fw.dSYM" 2>/dev/null || true
    local bid="org.pytorch.${name//_/-}"
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>$bid</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>$MIN</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$plat</string></array>
</dict>
</plist>
PLIST
}

rm -rf "$WORK" "$OUT"; mkdir -p "$WORK/device" "$WORK/sim" "$OUT"
for name in $LIBS; do
    make_framework "$DEV/$name.dylib" "$name" "$WORK/device" "iPhoneOS" 2
    ARGS=(-framework "$WORK/device/$name.framework" -debug-symbols "$WORK/device/$name.framework.dSYM")
    if [ "$HAVE_SIM" = 1 ]; then
        echo "==> $name.framework (device + sim) → xcframework"
        make_framework "$SIM/$name.dylib" "$name" "$WORK/sim" "iPhoneSimulator" 7
        ARGS+=(-framework "$WORK/sim/$name.framework" -debug-symbols "$WORK/sim/$name.framework.dSYM")
    else
        echo "==> $name.framework (device only) → xcframework"
    fi
    xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/$name.xcframework" >/dev/null
done
rm -rf "$WORK"
# One header tree next to the xcframeworks, so the project spec does not depend on
# which slice was built. The headers are identical across slices.
rm -rf "$OUT/include"; cp -R "$DEV/../include" "$OUT/include"
echo "==> done:"; ls "$OUT"
