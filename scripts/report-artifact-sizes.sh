#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="${1:-}"

emit() {
    if [[ -n "$OUTPUT_FILE" ]]; then
        printf '%s\n' "$1" >> "$OUTPUT_FILE"
    else
        printf '%s\n' "$1"
    fi
}

size_bytes() {
    wc -c < "$1" | tr -d ' '
}

emit "## Vane Artifact Sizes"
emit ""
emit "| Artifact | Size bytes |"
emit "|----------|------------|"

artifact_roots=(
    "$ROOT_DIR/VaneSwift/RustFramework.xcframework"
    "$ROOT_DIR/VaneSwift/RustFramework.small.xcframework"
    "$ROOT_DIR/VaneKotlin/library/src/main/jniLibs"
)
existing_roots=()
for root in "${artifact_roots[@]}"; do
    if [[ -d "$root" ]]; then
        existing_roots+=("$root")
    fi
done

if [[ "${#existing_roots[@]}" -gt 0 ]]; then
    while IFS= read -r file; do
        rel="${file#$ROOT_DIR/}"
        emit "| \`$rel\` | $(size_bytes "$file") |"
    done < <(
        find "${existing_roots[@]}" \
            -type f \( -name 'libvane.a' -o -name 'libvane.dylib' -o -name 'libvane.so' -o -name 'libquiche-*.so' \) \
            | sort
    )
fi

aar="$ROOT_DIR/VaneKotlin/library/build/outputs/aar/library-release.aar"
if [[ -f "$aar" ]]; then
    emit "| \`${aar#$ROOT_DIR/}\` | $(size_bytes "$aar") |"
fi

flutter_apk="$ROOT_DIR/vane_flutter/example/build/app/outputs/flutter-apk/app-debug.apk"
if [[ -f "$flutter_apk" ]]; then
    emit "| \`${flutter_apk#$ROOT_DIR/}\` | $(size_bytes "$flutter_apk") |"
fi
