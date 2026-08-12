#!/usr/bin/env bash
# Reports Vane release artifact sizes and gates the size posture defined by
# PERFORMANCE_PLAN.md "Phase 5b done" (CTO ruling,
# 2026-07-29):
#   - Trigger (FAILS this script): uncompressed native payload (sum of a
#     jniLibs ABI dir's .so files) on a device-shipping ABI -- arm64-v8a or
#     armeabi-v7a -- over 8,000,000 bytes. x86_64 is emulator/ChromeOS-only,
#     reported but never gated. 32-bit x86 is dropped from the build
#     entirely (vane-rs/Makefile build_so).
#   - Secondary smoke alarm (reported, does NOT fail): published AAR over
#     20,000,000 bytes -> flag for a payload audit, per the ruling this is
#     explicitly "NOT a demotion trigger".
# Calibration at the time of the ruling: arm64-v8a 5,451,992 B (~47%
# headroom), armeabi-v7a 3,192,376 B, AAR 9,953,850 B.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="${1:-}"

# Override via env for local testing only (e.g. proving the flag path with
# VANE_NATIVE_PAYLOAD_LIMIT_BYTES=1000000) -- the defaults are the ruling.
NATIVE_PAYLOAD_LIMIT_BYTES="${VANE_NATIVE_PAYLOAD_LIMIT_BYTES:-8000000}"
AAR_SMOKE_LIMIT_BYTES="${VANE_AAR_SMOKE_LIMIT_BYTES:-20000000}"

# App Bundle/Play delivers exactly one ABI slice per device; these two ship
# to real phones and are the only ones the trigger applies to.
DEVICE_SHIPPING_ABIS=" arm64-v8a armeabi-v7a "

emit() {
    if [[ -n "$OUTPUT_FILE" ]]; then
        printf '%s\n' "$1" >> "$OUTPUT_FILE"
    else
        printf '%s\n' "$1"
    fi
}

# GitHub Actions workflow-command annotations. Always to stdout/the live
# log (never just the summary file) -- these are what GitHub collects into
# the run's top-of-page annotations panel, the surface that stays visible
# even if nobody opens the job summary tab.
annotate() {
    printf '::%s::%s\n' "$1" "$2"
}

size_bytes() {
    wc -c < "$1" | tr -d ' '
}

is_device_shipping_abi() {
    case "$DEVICE_SHIPPING_ABIS" in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

GATE_FAILED=0
FAILED_ABIS=""

emit "## Vane Artifact Sizes"
emit ""
emit "Size posture per PERFORMANCE_PLAN.md \"Phase 5b done\"."
emit ""

# ---------------------------------------------------------------------------
# Android native payload per ABI -- the gated trigger.
# ---------------------------------------------------------------------------
emit "### Android native payload per ABI"
emit ""
emit "Sum of every \`.so\` in the ABI's jniLibs directory (\`libvane.so\` +"
emit "\`libquiche-*.so\`) -- what one device actually downloads for its ABI."
emit "**Trigger:** a device-shipping ABI (arm64-v8a, armeabi-v7a) over"
emit "$NATIVE_PAYLOAD_LIMIT_BYTES bytes uncompressed FAILS this job. x86_64 is"
emit "emulator/ChromeOS-only and is reported but never gated."
emit ""
emit "| ABI | Native payload (bytes) | Device-shipping | Status |"
emit "|-----|------------------------:|:----------------:|--------|"

jnilibs_dir="$ROOT_DIR/VaneKotlin/library/src/main/jniLibs"
if [[ -d "$jnilibs_dir" ]]; then
    for abi_dir in "$jnilibs_dir"/*/; do
        [[ -d "$abi_dir" ]] || continue
        abi="$(basename "$abi_dir")"
        total=0
        while IFS= read -r so_file; do
            total=$((total + $(size_bytes "$so_file")))
        done < <(find "$abi_dir" -type f -name '*.so' | sort)

        if is_device_shipping_abi "$abi"; then
            pct=$((total * 100 / NATIVE_PAYLOAD_LIMIT_BYTES))
            if [[ "$total" -gt "$NATIVE_PAYLOAD_LIMIT_BYTES" ]]; then
                emit "| \`$abi\` | $total | yes | 🚨 **FAIL: ${pct}% of budget, over the ${NATIVE_PAYLOAD_LIMIT_BYTES}B limit** |"
                annotate error "Vane size gate: $abi native payload is $total bytes (${pct}% of budget), over the ${NATIVE_PAYLOAD_LIMIT_BYTES}-byte device-shipping-ABI limit (PERFORMANCE_PLAN.md Phase 5b). Re-run per-feature attribution and demote the largest optional contributor."
                GATE_FAILED=1
                FAILED_ABIS="$FAILED_ABIS $abi"
            else
                emit "| \`$abi\` | $total | yes | ok (${pct}% of budget) |"
            fi
        else
            emit "| \`$abi\` | $total | no | reported only, not gated |"
        fi
    done
else
    emit "| _no jniLibs directory -- run \`make build_so\` first_ | | | |"
fi
emit ""

# ---------------------------------------------------------------------------
# Android AAR -- secondary smoke alarm only, never fails the job.
# ---------------------------------------------------------------------------
emit "### Android AAR"
emit ""
emit "Secondary smoke alarm only (NOT a demotion trigger): an AAR over"
emit "$AAR_SMOKE_LIMIT_BYTES bytes sums every shipped ABI plus bindings and may"
emit "mean accidental payload, but App Bundle delivers one ABI per device, so"
emit "this does not gate the job -- see PERFORMANCE_PLAN.md \"Phase 5b done\"."
emit ""
aar="$ROOT_DIR/VaneKotlin/library/build/outputs/aar/library-release.aar"
if [[ -f "$aar" ]]; then
    aar_size=$(size_bytes "$aar")
    emit "| Artifact | Size (bytes) | Status |"
    emit "|----------|---------------:|--------|"
    if [[ "$aar_size" -gt "$AAR_SMOKE_LIMIT_BYTES" ]]; then
        emit "| \`${aar#"$ROOT_DIR"/}\` | $aar_size | ⚠️ smoke alarm: audit for accidental payload |"
        annotate warning "Vane size smoke alarm: AAR is $aar_size bytes, over the ${AAR_SMOKE_LIMIT_BYTES}-byte secondary threshold. Not a release blocker -- audit AAR contents for accidental payload (PERFORMANCE_PLAN.md Phase 5b)."
    else
        emit "| \`${aar#"$ROOT_DIR"/}\` | $aar_size | ok |"
    fi
else
    emit "| _no release AAR -- run \`./gradlew :library:assembleRelease\` first_ | | |"
fi
emit ""

# ---------------------------------------------------------------------------
# Swift XCFramework .a slices -- reported, not gated (no iOS trigger yet;
# PERFORMANCE_PLAN.md "Phase 5b done": "iOS has no trigger and no
# measurement of record").
# ---------------------------------------------------------------------------
emit "### Swift XCFramework slices (\`.a\`, unlinked static archive)"
emit ""
emit "**\`.a\` size is NOT app-size impact.** It is unlinked object code --"
emit "no dead-code elimination has run -- so it is a ceiling, not a"
emit "prediction, of what an app linking this XCFramework will actually"
emit "contain. Do not read a \`.a\` delta as an app-size regression (see"
emit "PERFORMANCE_PLAN.md \"Phase 5b done\": a \`tcp-fallback\` \`.a\` delta of"
emit "+23.6 MB was really +1.71 MB once linked). Use the linked cdylib table"
emit "below instead."
emit ""
emit "| Slice | Size (bytes) |"
emit "|-------|---------------:|"
found_slice=0
for xcframework_name in RustFramework.xcframework RustFramework.small.xcframework; do
    xcframework_dir="$ROOT_DIR/VaneSwift/$xcframework_name"
    [[ -d "$xcframework_dir" ]] || continue
    while IFS= read -r archive; do
        found_slice=1
        emit "| \`${archive#"$ROOT_DIR"/}\` | $(size_bytes "$archive") |"
    done < <(find "$xcframework_dir" -type f -name 'libvane.a' | sort)
done
if [[ "$found_slice" -eq 0 ]]; then
    emit "| _no XCFramework -- run \`make build_swift\` first_ | |"
fi
emit ""

# ---------------------------------------------------------------------------
# Linked cdylib byproduct -- honest app-size proxy, cheap to report:
# vane-rs's crate-type list includes cdylib unconditionally (Android +
# UniFFI bindgen need it), so every Apple-target build already emits a
# linked libvane.dylib next to libvane.a. Same build, no extra compile.
# ---------------------------------------------------------------------------
emit "### Linked cdylib byproduct (honest app-size proxy)"
emit ""
emit "Not itself shipped (Swift packaging uses the static \`.a\`), but it"
emit "*has* been through a real link + dead-code-elimination pass, so its"
emit "size tracks real app-size impact far better than the archive above."
emit "Read straight from the Cargo build's own byproduct -- no extra build."
emit "**Caveat:** this reads whatever is currently in the Cargo target dir."
emit "CI's single sequential build guarantees it is the same invocation that"
emit "produced the \`.a\` above; a local tree with a concurrent/different"
emit "\`cargo build\` for the same triple (e.g. \`--no-default-features\`) can"
emit "leave a stale byproduct here without touching the packaged \`.a\` at"
emit "all -- cross-check the feature set if a number here looks surprising."
emit ""
target_dir="${CARGO_TARGET_DIR:-$ROOT_DIR/vane-rs/target}"
if [[ -d "$target_dir" ]]; then
    emit "| Target triple | Linked cdylib (bytes) |"
    emit "|----------------|------------------------:|"
    found_dylib=0
    while IFS= read -r dylib; do
        triple="$(basename "$(dirname "$(dirname "$dylib")")")"
        # Real target triples always contain a hyphen (arch-vendor-os[-abi]);
        # this excludes target/debug/deps and target/release/deps, which are
        # the plain host build's own internal copy, not a cross-target slice.
        case "$triple" in
            *-*) ;;
            *) continue ;;
        esac
        found_dylib=1
        emit "| \`$triple\` | $(size_bytes "$dylib") |"
    done < <(find "$target_dir" -mindepth 3 -maxdepth 3 -type f -name 'libvane.dylib' | sort)
    if [[ "$found_dylib" -eq 0 ]]; then
        emit "| _no libvane.dylib byproduct under \`${target_dir#"$ROOT_DIR"/}\` -- build first_ | |"
    fi
else
    emit "| _no cargo target dir at \`${target_dir#"$ROOT_DIR"/}\` -- build first_ | |"
fi
emit ""

# ---------------------------------------------------------------------------
# Flutter debug APK -- unrelated to the size gate, kept from the prior
# version of this script.
# ---------------------------------------------------------------------------
flutter_apk="$ROOT_DIR/vane_flutter/example/build/app/outputs/flutter-apk/app-debug.apk"
if [[ -f "$flutter_apk" ]]; then
    emit "### Flutter debug APK"
    emit ""
    emit "| Artifact | Size (bytes) |"
    emit "|----------|---------------:|"
    emit "| \`${flutter_apk#"$ROOT_DIR"/}\` | $(size_bytes "$flutter_apk") |"
    emit ""
fi

# ---------------------------------------------------------------------------
# Result banner, last so it's the final thing in the summary either way;
# mirrored as a GitHub Actions annotation so it survives even if nobody
# scrolls the summary body (the "warning nobody reads" failure mode).
# ---------------------------------------------------------------------------
if [[ "$GATE_FAILED" -eq 1 ]]; then
    emit "## SIZE GATE: FAIL"
    emit ""
    emit "Device-shipping ABI(s) over the ${NATIVE_PAYLOAD_LIMIT_BYTES}-byte limit:$FAILED_ABIS"
    emit ""
    annotate error "Vane size gate FAILED -- device-shipping ABI(s) over budget:$FAILED_ABIS. See the Artifact Sizes job summary."
    exit 1
fi

emit "## SIZE GATE: PASS"
