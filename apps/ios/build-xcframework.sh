#!/bin/bash
# Build the shared Rust core (oura-core) for iOS device + simulator, regenerate the
# UniFFI Swift bindings, and package the OuraCore.xcframework the app links.
# Re-run after changing any Rust core code or the #[uniffi::export] surface.
#
# The simulator-only dev harness (OuraApp/build_run.sh) refreshes just the sim slice;
# this produces BOTH slices, which a device build / TestFlight archive needs.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
GEN="$REPO/apps/ios/generated"
HEADERS="$GEN/headers" # UniFFI header + module.modulemap
OUT="$REPO/apps/ios/OuraCore.xcframework"
LIB="liboura_core.a"
CARGO="${CARGO:-cargo}"

for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
done

echo "==> build oura-core (release) for the host, then regenerate the Swift bindings"
$CARGO build -p oura-core --release
$CARGO run -p oura-core --release --bin uniffi-bindgen -- generate \
  --library "$REPO/target/release/liboura_core.dylib" \
  --language swift --out-dir "$GEN"
# The xcframework wants the header + a `module.modulemap` in one directory.
mkdir -p "$HEADERS"
cp "$GEN/oura_coreFFI.h" "$HEADERS/oura_coreFFI.h"
cp "$GEN/oura_coreFFI.modulemap" "$HEADERS/module.modulemap"

echo "==> build oura-core (release) for device + simulator"
$CARGO build -p oura-core --release --target aarch64-apple-ios
$CARGO build -p oura-core --release --target aarch64-apple-ios-sim
rm -rf "$OUT"

echo "==> create xcframework"
xcodebuild -create-xcframework \
  -library "$REPO/target/aarch64-apple-ios/release/$LIB" -headers "$HEADERS" \
  -library "$REPO/target/aarch64-apple-ios-sim/release/$LIB" -headers "$HEADERS" \
  -output "$OUT"
echo "✓ $OUT"
