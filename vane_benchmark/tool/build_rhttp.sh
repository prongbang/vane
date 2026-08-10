#!/usr/bin/env bash
# Builds rhttp's bundled Rust core so the benchmark can dlopen it on the host
# VM. Inside a real Flutter build cargokit does this automatically; `flutter
# test` never runs cargokit, so the dylib has to be built by hand once.
set -euo pipefail

: "${CARGO_TARGET_DIR:=$HOME/.cargo-target}"
export CARGO_TARGET_DIR

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$PKG_DIR/pubspec.lock" ]]; then
    echo "run 'flutter pub get' in $PKG_DIR first" >&2
    exit 1
fi

# The exact rhttp version pub resolved, from this package's lockfile.
VERSION="$(sed -n '/^  rhttp:/,/version:/s/.*version: "\(.*\)"/\1/p' "$PKG_DIR/pubspec.lock" | head -1)"
RUST_DIR="$HOME/.pub-cache/hosted/pub.dev/rhttp-$VERSION/rust"
if [[ ! -d "$RUST_DIR" ]]; then
    echo "rhttp $VERSION not in the pub cache at $RUST_DIR" >&2
    exit 1
fi

# reqwest gates its http3 feature behind this cfg; rhttp's own cargokit build
# sets the same flag (cargokit/build_tool/lib/src/builder.dart).
cd "$RUST_DIR"
RUSTFLAGS="--cfg reqwest_unstable" cargo build --release --locked

EXT="so"; [[ "$(uname)" == "Darwin" ]] && EXT="dylib"
echo "built $CARGO_TARGET_DIR/release/librhttp.$EXT"
