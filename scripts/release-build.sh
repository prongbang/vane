#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT_DIR/vane-rs"
KOTLIN_DIR="$ROOT_DIR/VaneKotlin"
SWIFT_DIR="$ROOT_DIR/VaneSwift"

: "${CARGO_TARGET_DIR:=$HOME/.cargo-target}"
export CARGO_TARGET_DIR

cd "$RUST_DIR"
cargo fmt --check
cargo test --release
cargo clippy --release --all-targets -- -D warnings
make build_kotlin
make build_swift
(
    cd vane-bindgen
    cargo run --bin uniffi-bindgen generate "$CARGO_TARGET_DIR/release/libvane.dylib" \
        --library \
        --language swift \
        --out-dir ../../VaneSwift/Sources/VaneSwift \
        --config uniffi.toml \
        --no-format
)
mv "$SWIFT_DIR/Sources/VaneSwift/vane.swift" "$SWIFT_DIR/Sources/VaneSwift/VaneClient.swift"
rm -f "$SWIFT_DIR/Sources/VaneSwift/vaneFFI.h" "$SWIFT_DIR/Sources/VaneSwift/vaneFFI.modulemap"

cd "$KOTLIN_DIR"
./gradlew :library:testDebugUnitTest :library:assembleDebugAndroidTest :library:assembleRelease

cd "$SWIFT_DIR"
swift test

cd "$ROOT_DIR"
if find VaneKotlin/library/src/main/jniLibs -name ".DS_Store" -print -quit | grep -q .; then
    echo "Unexpected .DS_Store found in Android native output" >&2
    exit 1
fi

echo "Release build completed."
