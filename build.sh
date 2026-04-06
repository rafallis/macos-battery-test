#!/usr/bin/env bash
# build.sh — Build the Rust dylib and the Swift CLI, then link them together.
#
# Usage:
#   ./build.sh               # arm64 only (Apple Silicon, default)
#   ./build.sh --universal   # fat binary (arm64 + x86_64)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$SCRIPT_DIR/rust-hook"
SWIFT_DIR="$SCRIPT_DIR/swift-cli"
RESOURCES_DIR="$SWIFT_DIR/Sources/battery-spoof/Resources"
DYLIB_NAME="libcyclecount.dylib"

UNIVERSAL=false
if [[ "${1:-}" == "--universal" ]]; then
    UNIVERSAL=true
fi

# ---------------------------------------------------------------------------
# 1. Build Rust dylib
# ---------------------------------------------------------------------------
echo "==> Building Rust dylib..."
pushd "$RUST_DIR" > /dev/null

if $UNIVERSAL; then
    cargo build --release --target aarch64-apple-darwin
    cargo build --release --target x86_64-apple-darwin
    mkdir -p target/universal-apple-darwin/release
    lipo -create \
        "target/aarch64-apple-darwin/release/$DYLIB_NAME" \
        "target/x86_64-apple-darwin/release/$DYLIB_NAME" \
        -output "target/universal-apple-darwin/release/$DYLIB_NAME"
    DYLIB_SRC="$RUST_DIR/target/universal-apple-darwin/release/$DYLIB_NAME"
else
    cargo build --release --target aarch64-apple-darwin
    DYLIB_SRC="$RUST_DIR/target/aarch64-apple-darwin/release/$DYLIB_NAME"
fi

popd > /dev/null
echo "    dylib built: $DYLIB_SRC"

# ---------------------------------------------------------------------------
# 2. Ad-hoc codesign the dylib
#    Required even with SIP off — dyld refuses to load completely unsigned dylibs.
# ---------------------------------------------------------------------------
echo "==> Codesigning dylib (ad-hoc)..."
codesign --force --sign - "$DYLIB_SRC"
echo "    signed."

# ---------------------------------------------------------------------------
# 3. Copy dylib into Swift package resources
# ---------------------------------------------------------------------------
echo "==> Copying dylib to Swift resources..."
mkdir -p "$RESOURCES_DIR"
cp "$DYLIB_SRC" "$RESOURCES_DIR/$DYLIB_NAME"
echo "    copied to $RESOURCES_DIR/$DYLIB_NAME"

# ---------------------------------------------------------------------------
# 4. Build Swift CLI
# ---------------------------------------------------------------------------
echo "==> Building Swift CLI..."
pushd "$SWIFT_DIR" > /dev/null
swift build -c release
popd > /dev/null

PRODUCT="$SWIFT_DIR/.build/release/battery-spoof"
echo "    binary: $PRODUCT"

# ---------------------------------------------------------------------------
# 5. Optional: codesign the Swift binary (ad-hoc, same reason as dylib)
# ---------------------------------------------------------------------------
echo "==> Codesigning Swift binary (ad-hoc)..."
codesign --force --sign - "$PRODUCT"
echo "    signed."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Build complete."
echo ""
echo "Quick test (reads real hardware value):"
echo "  $PRODUCT read"
echo ""
echo "Spoof example (ioreg):"
echo "  $PRODUCT run --count 999 -- ioreg -l -n AppleSmartBattery | grep CycleCount"
echo ""
echo "Spoof example (system_profiler):"
echo "  $PRODUCT run --count 999 -- system_profiler SPPowerDataType"
echo ""
echo "Launch System Settings with spoofed value:"
echo "  sudo $PRODUCT launch --count 999 --app 'System Settings'"
echo ""
echo "NOTE: System Settings and other Apple apps with Hardened Runtime require:"
echo "  1. SIP disabled (csrutil disable)"
echo "  2. sudo nvram boot-args=\"amfi_get_out_of_my_way=1\"  (then reboot once)"
