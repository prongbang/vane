#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT_DIR/vane-rs"
KOTLIN_DIR="$ROOT_DIR/VaneKotlin"
SWIFT_DIR="$ROOT_DIR/VaneSwift"
FLUTTER_DIR="$ROOT_DIR/vane_flutter"

: "${CARGO_TARGET_DIR:=$HOME/.cargo-target}"
export CARGO_TARGET_DIR

cd "$RUST_DIR"
cargo fmt --check
cargo test --release
cargo clippy --release --all-targets -- -D warnings
make build_kotlin
make build_swift
# The small profile is tracked in git and consumed by anyone who swaps it in,
# but nothing at build or load time notices it going stale: adding a UniFFI
# record field does not move a function checksum, so a small archive built
# against an older record reads N+1 fields out of an N-field RustBuffer and
# traps on every response. Build it here rather than by hand.
make build_swift_small
(
    cd vane-bindgen
    cargo run --bin uniffi-bindgen generate "$CARGO_TARGET_DIR/release/libvane.dylib" \
        --language swift \
        --out-dir ../../VaneSwift/Sources/VaneSwift \
        --config uniffi.toml \
        --no-format
)
mv "$SWIFT_DIR/Sources/VaneSwift/vane.swift" "$SWIFT_DIR/Sources/VaneSwift/VaneClient.swift"
# The XCFramework's vaneFFI.h is written by cargo-swift's own bundled
# uniffi-bindgen, which is pinned to an older uniffi than this crate compiles
# against: since uniffi 0.30 an object handle is a uint64_t, not a void*, so
# that header no longer describes the scaffolding inside libvane.a and the
# Swift package fails to build. Ship the header from the same uniffi that
# produced the scaffolding. The modulemap next to it is version-independent
# and cargo-swift's copy is left alone.
# Both XCFrameworks, not just the one this script builds: the small profile is
# tracked in git and differs only in cargo features, which do not change the
# UniFFI surface, so it needs the same header. Leaving it out is how it ended up
# shipping a uniffi 0.29 header against 0.31 scaffolding.
for xcframework in "$SWIFT_DIR"/RustFramework*.xcframework; do
    [ -d "$xcframework" ] || continue
    find "$xcframework" -name vaneFFI.h \
        -exec cp "$SWIFT_DIR/Sources/VaneSwift/vaneFFI.h" {} \;
done
rm -f "$SWIFT_DIR/Sources/VaneSwift/vaneFFI.h" "$SWIFT_DIR/Sources/VaneSwift/vaneFFI.modulemap"

cd "$KOTLIN_DIR"
./gradlew :library:testDebugUnitTest :library:assembleDebugAndroidTest :library:assembleRelease

cd "$SWIFT_DIR"
swift test

if [[ -d "$FLUTTER_DIR" ]]; then
    cd "$FLUTTER_DIR"
    flutter analyze
    flutter test
    (
        cd example
        flutter build apk --debug
        flutter build ios --debug --simulator
    )
fi

cd "$ROOT_DIR"
if find VaneKotlin/library/src/main/jniLibs -name ".DS_Store" -print -quit | grep -q .; then
    echo "Unexpected .DS_Store found in Android native output" >&2
    exit 1
fi

echo "Release build completed."
