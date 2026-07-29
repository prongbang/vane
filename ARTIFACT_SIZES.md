# Vane Artifact Sizes

Re-measured on 2026-07-29 (PERFORMANCE_PLAN.md Phase 5) after batch 3
reintroduced the `reqwest` TCP fallback backend (HTTP/1.1 + HTTP/2 + TLS
1.2/1.3, feature `tcp-fallback`) and added the `psl` public-suffix cookie
guard — both now **default-on** alongside `spki-pinning`
(`default = ["spki-pinning", "tcp-fallback", "psl"]` in `vane-rs/Cargo.toml`).
This supersedes the 2026-06-12 measurement below, which was HTTP/3-only with
`reqwest` removed; that description is no longer accurate for the default
profile and the numbers in this pass are larger across every slice as a
direct result. All artifacts were rebuilt from the committed `main` tip
(vane-rs `77b757d`) via the exact `vane-rs/Makefile` recipes — no numbers in
this file are estimated. See "Per-feature size attribution" and "Phase 5
verdicts" below for the breakdown the CTO revisit triggers are gated on.

The default profile is `quiche` HTTP/3 plus the `reqwest`/`rustls` TCP
fallback (HTTP/1.1, HTTP/2, TLS 1.2/1.3), SPKI + cert-DER certificate
pinning, the `psl`-backed cookie `Domain` guard, connection pooling, retry
policy, Swift/Kotlin request helper work, the opt-in in-memory cookie jar,
configurable request/response body limits, and the Swift static XCFramework
migration.

## Swift XCFramework

Full production profile (`make build_swift`, default features): `quiche`
HTTP/3 **and** the `reqwest`/`rustls` TCP fallback, SPKI and cert-DER
certificate pins, `psl` cookie `Domain` guard, cookies, retries, connection
pooling, and body limits. Sizes are the packaged `libvane.a` inside each
XCFramework slice — post `xcrun strip -S -x` and the bitcode-strip/`libtool`
re-link in `scripts/strip-swift-archives.sh`, i.e. exactly what
`make build_swift` produces, nothing extra and nothing skipped.

| Slice | File | Size (2026-07-29) | Size (2026-06-12) | Delta |
|-------|------|-------------------:|-------------------:|------:|
| macOS arm64/x86_64 | `VaneSwift/RustFramework.xcframework/macos-arm64_x86_64/libvane.a` | 94,974,440 bytes | 39,965,144 bytes | +55,009,296 (+137.6%) |
| iOS simulator arm64/x86_64 | `VaneSwift/RustFramework.xcframework/ios-arm64_x86_64-simulator/libvane.a` | 99,397,008 bytes | 45,369,992 bytes | +54,027,016 (+119.1%) |
| iOS arm64 | `VaneSwift/RustFramework.xcframework/ios-arm64/libvane.a` | 49,800,520 bytes | 22,571,208 bytes | +27,229,312 (+120.6%) |

The jump is `tcp-fallback` (reqwest + rustls + tokio + hyper +
rustls-platform-verifier) plus `psl`, both newly default-on since the last
measurement — see "Per-feature size attribution" for the isolated cost of
each. **Important caveat for interpreting these numbers as end-user app-size
impact:** `libvane.a` is an unlinked static archive (`ar` of the fat-LTO'd
object code for the whole crate graph); unlike a shared library it has not
been through a linker's dead-code elimination pass, so it is a ceiling on
what a real iOS app binary will contain after Xcode links against the
XCFramework and strips whatever the app doesn't reference, not a prediction
of the exact IPA delta. The per-feature section below quantifies the gap
using the `cdylib` byproduct (which *is* linked) as a proxy.

Small Swift profile: built with `make build_swift_small`
(`--no-default-features`, i.e. **zero** of `spki-pinning`, `tcp-fallback`,
`psl`). It is HTTP/3-only (no TCP fallback) and supports only
`sha256-cert/<base64-cert-der-sha256>` certificate pins (the SPKI pin variant
needs `spki-pinning`).

Correction to the prior note here: measured per-feature (below), the SPKI pin
parser itself is *not* what makes the small profile smaller — it costs only
~12 KB on this slice, because `quiche`'s own default TLS backend already
pulls in BoringSSL (`boring`/`boring-sys`) unconditionally, feature or no
feature; `spki-pinning` just adds a thin SPKI-DER extraction shim on top of a
dependency that was compiled in either way. The two features that actually
move this needle are `tcp-fallback` and, to a much smaller extent, `psl` —
both of which the small profile also drops. `psl` additionally controls
`Set-Cookie` `Domain` validation: without it, a bare-TLD (`com`) or
IP-literal `Domain` is still refused (the dot/IP-literal guard is
unconditional), but a multi-label public suffix (`co.uk`, `github.io`) is
not. Cookies are off by default in either profile.

Measured cost of `psl` on the host macOS release dylib (`opt-level = "z"`,
fat LTO, stripped), recorded as the original Phase 5 baseline (unchanged,
not re-measured this pass — see the mobile-slice figures below instead):

| Profile | Size |
|---------|------|
| H3 only, no `psl` | 1,748,272 bytes |
| H3 only, with `psl` | 2,294,368 bytes (+546,096, +31%) |

| Slice | File | Size (2026-07-29) | Size (2026-06-12) | Delta |
|-------|------|-------------------:|-------------------:|------:|
| macOS arm64/x86_64 | `VaneSwift/RustFramework.small.xcframework/macos-arm64_x86_64/libvane.a` | 40,944,064 bytes | 45,520,048 bytes | -4,575,984 (-10.1%) |
| iOS simulator arm64/x86_64 | `VaneSwift/RustFramework.small.xcframework/ios-arm64_x86_64-simulator/libvane.a` | 46,386,056 bytes | 56,948,240 bytes | -10,562,184 (-18.5%) |
| iOS arm64 | `VaneSwift/RustFramework.small.xcframework/ios-arm64/libvane.a` | 23,081,384 bytes | 28,159,464 bytes | -5,078,080 (-18.0%) |

The small profile got *smaller* than the 2026-06-12 baseline (it carries the
same feature set now as then, `--no-default-features`); the toolchain is
newer (`rustc 1.93.1` vs whatever built the June numbers) and some Phase
1-4 code landed since, both plausible explanations, neither re-verified here
since it wasn't the object of this pass. It is the full-profile growth that
matters for the CTO triggers, not this incidental improvement.

## Android Native Libraries

Built via `make build_so` (`cargo ndk`, default features: `tcp-fallback` +
`psl` + `spki-pinning`), all four ABIs. `libvane.so` is the crate itself;
`libquiche-<hash>.so` is `quiche`'s own build-script output (the hash in the
filename is content/session-derived and changes build-to-build, hence
`build_so` does `rm -rf jniLibs` first — this is expected churn, not a
regression).

| ABI | File | Size (2026-07-29) | Size (2026-06-12) | Delta |
|-----|------|-------------------:|-------------------:|------:|
| armeabi-v7a | `VaneKotlin/library/src/main/jniLibs/armeabi-v7a/libvane.so` | 3,184,748 bytes | 1,298,480 bytes | +1,886,268 (+145.3%) |
| armeabi-v7a | `VaneKotlin/library/src/main/jniLibs/armeabi-v7a/libquiche-8283fe381cc37f06.so` | 7,652 bytes | 7,788 bytes | -136 |
| x86 | `VaneKotlin/library/src/main/jniLibs/x86/libvane.so` | 5,419,764 bytes | 2,095,044 bytes | +3,324,720 (+158.7%) |
| x86 | `VaneKotlin/library/src/main/jniLibs/x86/libquiche-99241bd51e48d90d.so` | 336,056 bytes | 336,028 bytes | +28 |
| arm64-v8a | `VaneKotlin/library/src/main/jniLibs/arm64-v8a/libvane.so` | 5,141,776 bytes | 2,091,440 bytes | +3,050,336 (+145.9%) |
| arm64-v8a | `VaneKotlin/library/src/main/jniLibs/arm64-v8a/libquiche-f910ff53b77b4674.so` | 310,248 bytes | 310,416 bytes | -168 |
| x86_64 | `VaneKotlin/library/src/main/jniLibs/x86_64/libvane.so` | 5,924,776 bytes | 2,342,400 bytes | +3,582,376 (+153.0%) |
| x86_64 | `VaneKotlin/library/src/main/jniLibs/x86_64/libquiche-f94a26b14538b789.so` | 341,024 bytes | 340,632 bytes | +392 |

`libquiche-*.so` is essentially unchanged (as expected — `quiche` itself
didn't change); the entire per-ABI growth is in `libvane.so`, i.e. the new
default features. See "Per-feature size attribution" for the isolated
`tcp-fallback` cost per ABI (this table's delta also includes `psl`, which
was already in the 2026-06-12 default, plus incidental Phase 1-4 code
growth — it is *not* a pure `tcp-fallback` number).

## Android AAR

Built via `ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :library:assembleRelease`
against the fresh `jniLibs` above. Committed Kotlin bindings (`Vane.kt`,
unmodified since 2026-06-13) were reused as-is, not regenerated via
`vane-bindgen/generate.sh` — per PERFORMANCE_PLAN.md's batch 1-3 status notes,
tcp-fallback and psl landed with no exported UniFFI/ABI surface change, and a
Gradle `assembleRelease` doesn't itself verify native symbol compatibility
(that's a runtime JNI concern, not a build-time one), so this measurement
takes that record at its word rather than independently re-verifying it via
symbol diffing, which was out of scope for a size pass.

| Artifact | File | Size (2026-07-29) | Size (2026-06-12) | Delta |
|----------|------|-------------------:|-------------------:|------:|
| Release AAR | `VaneKotlin/library/build/outputs/aar/library-release.aar` | 9,953,850 bytes | 4,517,048 bytes | +5,436,802 (+120.4%) |

9,953,850 bytes = 9.49 MiB = 9.95 MB (decimal) — see "Phase 5 verdicts" below;
this is effectively at the CTO's "~10 MB" revisit trigger, not comfortably
under it.

## Per-feature size attribution (Phase 5)

Isolates `tcp-fallback` and `psl` from each other and from `spki-pinning`, on
the two slices that ship to users: Android arm64-v8a and iOS device
(`aarch64-apple-ios`). Built directly with `cargo ndk` / `cargo build
--target aarch64-apple-ios --release` per feature combination (raw artifact,
not the full `make build_swift`/`build_so` packaging pipeline — per-Makefile
packaging was validated separately to add no attribution error, see the iOS
note below). `ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/28.2.13676358`,
`IPHONEOS_DEPLOYMENT_TARGET=13.0`, same `Cargo.lock`, same machine, same pass.

### Android arm64-v8a

`libvane.so`, raw `cargo ndk` output = shipped form (`build_so` does no extra
post-processing beyond what's in this table already).

| Feature set | Size | Δ vs previous row | Attributed to |
|---|---:|---:|---|
| `--no-default-features` (zero) | 2,161,480 bytes | — | baseline (H3 core only) |
| `--features spki-pinning` | 2,166,608 bytes | +5,128 bytes | `spki-pinning`'s own glue code |
| `--features spki-pinning,psl` | 2,729,168 bytes | +562,560 bytes | `psl` |
| default (+`tcp-fallback`) | 5,141,776 bytes | +2,412,608 bytes | `tcp-fallback` |

### iOS device, `aarch64-apple-ios`

Two views of the same four builds. The `.a` is what's literally inside the
XCFramework; the `.dylib` is a build byproduct (Cargo builds all three
`crate-type`s every time) that **has** been through a real link + dead-code
elimination step, and is a much better proxy for the eventual app-binary
delta — see the caveat under "Swift XCFramework" above. Packaging
methodology was validated by round-tripping the `default` `.a` through
`xcrun strip -S -x` + `scripts/strip-swift-archives.sh` and confirming it
reproduces the real `make build_swift` output byte-for-byte (49,800,520 —
matches the main table exactly).

`.a` staticlib, packaged (i.e. same strip/bitcode-strip treatment `make
build_swift` applies — pre-app-link, see caveat):

| Feature set | Size | Δ vs previous row |
|---|---:|---:|
| zero | 23,081,384 bytes | — |
| `spki-pinning` | 23,093,648 bytes | +12,264 bytes |
| `spki-pinning,psl` | 26,209,136 bytes | +3,115,488 bytes |
| default | 49,800,520 bytes | +23,591,384 bytes |

`.dylib` cdylib byproduct, linked (not itself shipped, but shows what
`tcp-fallback`/`psl` actually cost once dead code is eliminated):

| Feature set | Size | Δ vs previous row | Attributed to |
|---|---:|---:|---|
| zero | 1,750,888 bytes | — | baseline |
| `spki-pinning` | 1,750,944 bytes | +56 bytes | `spki-pinning`'s own glue code |
| `spki-pinning,psl` | 2,292,800 bytes | +541,856 bytes | `psl` |
| default (+`tcp-fallback`) | 4,003,644 bytes | +1,710,844 bytes | `tcp-fallback` |

The `.dylib` deltas track the Android numbers closely (`psl`: 542 KB on iOS
vs 563 KB on Android vs 546 KB on the original host measurement;
`spki-pinning`: under 100 bytes on both) — three independent, differently-
built artifacts landing in the same range is the cross-check that these
per-feature numbers are real. The `.a` deltas do not track them (`psl`
looks like +3.1 MB, `tcp-fallback` like +23.6 MB) purely because the `.a` is
unlinked; treat the `.dylib`/Android numbers as the attribution that
matters and the `.a` numbers as "what's in the XCFramework today."

`quiche` links BoringSSL (`boring`/`boring-sys`) as its own default TLS
backend regardless of vane's `spki-pinning` Cargo feature — that feature
only gates a small amount of vane's own SPKI-DER extraction code on top of
an already-present dependency. This is why `spki-pinning`'s isolated cost is
a few KB, not the multi-megabyte figure the old "removes the SPKI pin parser
to reduce size" framing implied.

## Phase 5 verdicts (CTO revisit triggers)

From batch 3 (PERFORMANCE_PLAN.md): *"Revisit if Phase 5 shows >4 MB added
per Android ABI or the AAR crossing ~10 MB."*

**Trigger 1 — `tcp-fallback` adds >4 MB per Android ABI: NOT CROSSED.**
Isolated cost on arm64-v8a is 2,412,608 bytes (2.30 MiB / 2.41 MB), about
60% of the 4 MB budget. arm64-v8a and iOS device were the two slices
isolated per the measurement brief; the other three Android ABIs were not
individually isolated, but each has a hard upper bound from this pass — the
full old-default-to-new-default delta in the main table above, which is
`tcp-fallback` + `psl` (already default before this pass) + incidental
Phase 1-4 code growth, i.e. `tcp-fallback`'s true share is *at most* that
number:

| ABI | Upper bound on `tcp-fallback` alone | vs 4 MB budget |
|---|---:|---|
| armeabi-v7a | 1,886,268 bytes (1.80 MiB) | under |
| x86 | 3,324,720 bytes (3.17 MiB) | under |
| arm64-v8a | 2,412,608 bytes (2.30 MiB, isolated exactly) | under |
| x86_64 | 3,582,376 bytes (3.42 MiB) | under |

Every ABI is under the 4 MB/ABI trigger, including the loosest (least
favorable) bound. Verdict: do not demote `tcp-fallback` on this trigger.

**Trigger 2 — release AAR crosses ~10 MB: EFFECTIVELY CROSSED.** Measured
9,953,850 bytes = 9.95 MB (decimal) / 9.49 MiB, up from 4,517,048 bytes
(+120%). This is within 0.5% of the stated "~10 MB" line — given the "~" and
that this number moved from comfortably-under to essentially-at-the-line in
one pass, the honest read is that this trigger has fired, not that it's
still safe. Verdict: this alone is grounds for the CTO to make the
opt-in-vs-default call now rather than waiting for a future pass to cross
10,000,000 on the nose.

**Combined read:** the two triggers disagree — the per-ABI `.so` growth is
comfortably under budget, but the AAR (which sums all four ABIs plus the
Kotlin bindings) is at the line. That's expected: the AAR trigger is the
stricter one by construction, since it accumulates all four ABIs' growth
into one artifact. If the CTO's real concern is total download/APK-size
impact (what the AAR trigger is a proxy for) rather than any single ABI,
trigger 2 is the one to act on.

**`psl` mobile-slice cost:** ~540-565 KB per slice
(Android arm64-v8a: +562,560 bytes; iOS device, dead-code-eliminated
equivalent: +541,856 bytes), consistent with the +546,096-byte host
measurement already on record. No surprises, no threshold implications —
`psl` was already correctly identified as the cheap, droppable feature; this
confirms the drop is worth about half a megabyte, not a false economy, and
`tcp-fallback` (not `psl`) is what drives both triggers above.

Everything in this section built successfully in this environment; nothing
is estimated or unmeasured. Toolchain used: `rustc 1.93.1`, `cargo-ndk
4.1.2`, NDK 28.2.13676358 (`ANDROID_NDK_HOME`), `cargo-swift 0.9.0`, Xcode
26.1.1, Gradle 8.13 (wrapper) / AGP via `compileSdk 36`.
