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
using the `cdylib` byproduct (which *is* linked) as a proxy; **"iOS
app-size impact" below now measures the real thing** by archiving an actual
app against both XCFrameworks — the linked delta is 10.6x smaller than this
table's `.a` delta suggests.

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

## iOS app-size impact (measured 2026-07-29)

**These are not the `.a` sizes above and must never be quoted
interchangeably with them.** Everything in the "Swift XCFramework" table is
an *unlinked* `ar` archive: a ceiling on what an app could contain, roughly
an order of magnitude above what one actually does. This section is the
measured other end — a real iOS app, archived for a real device, with the
linker's dead-code elimination applied. It closes the "iOS has no
measurement of record" gap in PERFORMANCE_PLAN.md Phase 5b.

### What was built

A throwaway single-screen SwiftUI app (`Probe`), one `Text` + one `Button`,
built three ways from one identical source file gated on a compilation
condition:

| Variant | What the button does | Links |
|---|---|---|
| `none` | `URLSession.shared.data(from:)` GET | nothing extra (baseline) |
| `small` | `try VaneSession().get(...)` | `RustFramework.small.xcframework` |
| `full` | `try VaneSession().get(...)` | `RustFramework.xcframework` |

`none` is the adopter's real counterfactual: an app that already makes an
HTTPS GET with the OS-provided stack. The `small`/`full` variants go through
`VaneSession()` → `createVaneClient()` → the Rust FFI, so the framework is
genuinely reachable, not a dead-strippable bare `import`.

The two vane variants consume `VaneSwift` exactly as a real adopter does —
as a local SwiftPM package with the `binaryTarget` pointing at the
XCFramework under test — using a copy of the repo's `Package.swift`
(Alamofire and the test target stripped) and unmodified copies of
`Sources/VaneSwift/*.swift`. No repo file was changed to take these
measurements.

### Linkage verification (not assumed)

Archive builds are stripped (`STRIP_INSTALLED_PRODUCT=YES`,
`STRIP_STYLE=all`), so a parallel `STRIP_INSTALLED_PRODUCT=NO` build of each
vane variant was made purely to read its symbol table. `nm` on those:

| Symbol group | `small` | `full` |
|---|---:|---:|
| `uniffi_vane_fn_func_*` exports | 17 | 17 |
| `ffi_vane_rustbuffer_*` | 2 | 2 |
| `quiche::*` (Rust-mangled) | 278 | 278 |
| BoringSSL (`SSL_CTX_new` etc.) | present | present |
| `rustls::*` | 0 | 828 |
| `hyper::*` | 0 | 540 |
| `tokio::*` | 0 | 689 |
| `reqwest::*` | 0 | 201 |
| `ring_core_*` | 0 | 73 |

This is the confirmation that (a) the framework really is linked in — the
UniFFI exports and all 278 `quiche` symbols survive dead-code stripping in
both — and (b) the two profiles differ by exactly the `tcp-fallback` stack
and nothing else. It also re-confirms independently that BoringSSL is
present in *both* profiles via `quiche`, consistent with the `spki-pinning`
correction above.

### Measured sizes (bytes)

Release, `arm64`, `generic/platform=iOS`, `xcodebuild archive`, stripped.

| Variant | app binary | `.app` (unsigned) | `.app` (ad-hoc signed) | `.ipa` (ad-hoc signed) |
|---|---:|---:|---:|---:|
| `none` | 76,336 | 77,190 | 97,939 | 14,373 |
| `small` | 2,050,840 | 2,051,694 | 2,087,875 | 1,069,291 |
| `full` | 4,562,840 | 4,563,694 | 4,619,491 | 2,464,569 |

### The numbers that matter

**Cost of adding vane to an iOS app** (vs. the same app using `URLSession`):

| | app binary / install | `.ipa` / download |
|---|---:|---:|
| small profile (`build_swift_small`) | +1,974,504 (1.88 MiB) | +1,054,918 (1.01 MiB) |
| full profile (`build_swift`, default) | +4,486,504 (4.28 MiB) | +2,450,196 (2.34 MiB) |

**Delta between the two profiles** — what a user buys by dropping to
`--no-default-features`:

| | full − small |
|---|---:|
| app binary | **2,512,000 bytes (2.40 MiB / 2.51 MB)** |
| `.app`, ad-hoc signed | 2,531,616 bytes |
| `.ipa`, ad-hoc signed | **1,395,278 bytes (1.33 MiB / 1.40 MB)** |

For scale: the same delta read off the `.a` files is 26,719,136 bytes. The
unlinked archive overstates the real linked binary delta by **10.6x**, and
the real download delta by **19.1x**. That is the concrete justification for
the standing rule never to quote `.a` sizes as app impact.

### Segment breakdown (on-disk `filesize`, stripped binary)

| Segment | `none` | `small` | `full` | full − small |
|---|---:|---:|---:|---:|
| `__TEXT` | 32,768 | 1,753,088 | 3,784,704 | +2,031,616 |
| `__DATA_CONST` | 16,384 | 114,688 | 245,760 | +131,072 |
| `__DATA` | 16,384 | 16,384 | 32,768 | +16,384 |
| `__LINKEDIT` | 10,800 | 166,680 | 499,608 | +332,928 |

81% of the full-vs-small delta is executable code in `__TEXT`; the rest is
relocations/metadata. Nothing is asset- or resource-driven, which is why
app thinning is a no-op here (see caveats).

### The `cdylib` proxy was right, and is now retired

PERFORMANCE_PLAN.md's interim posture was "the linked cdylib proxy stands."
It does. The `aarch64-apple-ios` cdylib byproduct predicted a
`tcp-fallback`+`psl` delta of 2,252,756 bytes; the real archived app binary
delta is 2,512,000 — the proxy under-predicted by 10.3%. In absolute terms
the default-profile cdylib is 4,003,644 vs. vane's real 4,486,504-byte
contribution to the app binary (proxy = 89.2% of real). The proxy is a good
estimator and errs slightly optimistic; use these archived numbers instead
now that they exist.

### Method (reproducible)

Xcode 26.1.1 (17B100), Swift 6.2.1, iOS SDK 26.1, deployment target 15.0,
`SWIFT_OPTIMIZATION_LEVEL=-O`, `SWIFT_COMPILATION_MODE=wholemodule`,
`DEAD_CODE_STRIPPING=YES`, `STRIP_STYLE=all`, `ARCHS=arm64`,
`TARGETED_DEVICE_FAMILY=1`, no asset catalog. Project generated with
XcodeGen 2.45.4.

1. Copy `VaneSwift/Package.swift` (drop the Alamofire conditional and the
   test target) and `VaneSwift/Sources/VaneSwift/*.swift` into a scratch
   package; symlink `RustFramework.xcframework` there to the profile under
   test (`RustFramework.xcframework` or `RustFramework.small.xcframework`).
   Use one scratch package per profile — do not flip a symlink under a
   single package, Xcode caches the resolved binary target.
2. Generate an app project depending on that local package, with the
   SwiftUI source above; a third project with no package for the baseline.
3. Archive each:
   ```
   xcodebuild archive -project <P>.xcodeproj -scheme Probe \
     -configuration Release -destination 'generic/platform=iOS' \
     -archivePath <out>.xcarchive -derivedDataPath <dd> \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
   ```
4. `.ipa`: `mkdir -p Payload && cp -R <archive>/Products/Applications/Probe.app
   Payload/ && codesign -f -s - --timestamp=none Payload/Probe.app &&
   zip -q -r -X out.ipa Payload`.
5. Segments: `otool -l <binary>` (`filesize` per `LC_SEGMENT_64`).
   Linkage: repeat step 3 with `STRIP_INSTALLED_PRODUCT=NO` and run `nm`.

### Caveats — which numbers are real and which are proxies

**Real, measured, unqualified:** every byte count in the tables above, and
therefore every delta. The deltas are the load-bearing figures and they are
unaffected by the caveats below, because the same substitution applies to
all three variants identically.

**Signing could not be done properly in this environment.** No Apple
Developer account is configured in Xcode and there are no provisioning
profiles installed (`~/Library/MobileDevice/Provisioning Profiles` is
empty), so `xcodebuild archive` with `CODE_SIGN_STYLE=Automatic
DEVELOPMENT_TEAM=... -allowProvisioningUpdates` fails with *"No Account for
Team"* / *"No profiles for 'com.example.vaneprobe' were found"*, and
`xcodebuild -exportArchive` is therefore not reachable either. Substituted:
unsigned archives, plus an ad-hoc `codesign -s -` pass to recover realistic
signature overhead (a code-directory hash page per 4 KiB, ~1.2% of the
binary). A properly signed `.ipa` would additionally carry
`embedded.mobileprovision` (~10-20 KB) and a real CMS blob — a constant
across all three variants, so it moves the absolute `.ipa` figures by a few
tens of KB and the deltas not at all.

**"Thinned" `.ipa`.** No thinning step was run, and none applies: the app is
single-architecture `arm64` with no asset catalog, no on-demand resources
and no bitcode (removed in Xcode 14+), so an exported thinned `.ipa` is the
same payload. The `.ipa` figures are `zip -X` of `Payload/` at default
deflate — a proxy for *download* size, not an App Store figure (Apple
re-encrypts and re-compresses; the authoritative number is the App Thinning
Size Report from a real upload). The `.app` byte counts are the install-size
figures and need no such qualification.

**Baseline choice.** `none` uses `URLSession` rather than making no network
call at all, so the +1.97/+4.49 MB figures answer "what does replacing the
OS stack with vane cost me" rather than "what does adding a network call
cost me". `URLSession` is OS-provided, so the difference between those two
framings is negligible (the whole baseline binary is 76 KB).

**Not measured:** per-feature attribution *within* an archived app (only
full-vs-small was archived, not the four feature combinations the `.a`
/cdylib section isolates); macOS and simulator slices; and any app large
enough for its own code to interact with vane's via LTO. A 76 KB baseline
app is the cleanest possible measurement of vane in isolation, which is also
its limitation.

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

## Phase 5a — opt-level override, measured and KEPT 2026-07-29

PERFORMANCE_PLAN.md Phase 5a: the workspace release profile is
`opt-level = "z"` (size-first), applied to dependencies too, including
`quiche`'s packet/QPACK code and `sha2`. Added, same machine/toolchain as
the per-feature attribution pass above, same `Cargo.lock`:

```toml
[profile.release.package.quiche]
opt-level = 3
[profile.release.package.sha2]
opt-level = 3
```

`ring` (pulled in via rustls for `tcp-fallback`) was considered and left
out. Checked the vendored source rather than assuming: `ring-0.17.14`'s
`build.rs` compiles ~90 hand-written assembly/perlasm files per target arch
(`crypto/fipsmodule/**/asm/*.pl`, `crypto/chacha/asm/*.pl`,
`third_party/fiat/asm/*.S`, ...) for exactly the primitives on its hot path
(AES-GCM, ChaCha20-Poly1305, SHA-2, P-256, Curve25519). Those are compiled
by `cc`/an assembler and are already outside rustc's `opt-level`, same as
BoringSSL's C code. An override would only reach ring's thin non-hot Rust
glue, so it was not added — not a speculative inclusion, a checked exclusion.

### Throughput

`examples/bench.rs` against `cloudflare-quic.com`, 3 runs each side, same
session: **no resolvable difference**, as anticipated (RTT-dominated). Warm
pool-on p50 moved 73.3 ms &rarr; 62.2 ms, but the CPU math below (a few
hundred ns saved per request) cannot explain an 11 ms gap — that is network
variance, not a measured win, and is reported as such rather than claimed.

Bench could not resolve it, so the CPU paths were timed directly instead:
a throwaway example (not committed, deleted after use) called `quiche`'s own
public QPACK codec (`quiche::h3::qpack::{Encoder,Decoder}`, `#[doc(hidden)]`
but genuinely `pub`) and `sha2::Sha256::digest` — the exact two dependencies
the override targets — with no network involved. 500k iterations/side,
3 runs each, low variance:

| Path | Before (ns/op) | After (ns/op) | Delta |
|---|---:|---:|---:|
| QPACK encode | 653.6 | 596.5 | -8.7% |
| QPACK decode | 1808.3 | 1586.7 | -12.2% |
| SHA-256 (550-byte buf) | 2044.7 | 992.7 | **-51.4% (~2.06x)** |

The 550-byte buffer matches what `sha256_pin()` (`lib.rs`) hashes for
`spki-pinning`/cert-DER pin checks — note this path only runs when the
caller configures `certificate_pins` for the host; `bench.rs`'s default
config has none, so `bench.rs` never exercises `sha2` at all, independent of
the RTT-dominance argument. QPACK encode/decode runs on every request
(headers out, headers in) regardless of pinning, which is why it shows up in
`bench.rs`'s call path even though its ~250 ns/request saving is invisible
next to tens of milliseconds of RTT.

### Size

Same before/after pair, same session. "Before" is the tree as committed
(`ea394870`, VaneKotlin `88d93ee`); "after" is with the override above.

**Android arm64-v8a**, default features, raw `cargo ndk build --release
--target aarch64-linux-android` output (`ANDROID_NDK_HOME` = NDK
28.2.13676358) — the native payload the CI gate (`scripts/report-artifact-sizes.sh`,
8,000,000-byte trigger on a device-shipping ABI) sums:

| File | Before | After | Delta |
|---|---:|---:|---:|
| `libvane.so` (linked, shipped, DCE'd against vane's actual usage) | 5,157,848 | 5,201,384 | +43,536 (+0.84%) |
| `libquiche-<hash>.so` (quiche's own cdylib build byproduct — quiche declares `crate-type = ["lib", "staticlib", "cdylib"]`, so Cargo builds it regardless of whether vane needs it; not DCE'd against vane's usage, carries quiche's full compiled surface) | 310,248 | 495,608 | +185,360 (+59.75%) |
| **Total native payload (gate input)** | **5,468,096** | **5,696,992** | **+228,896 (+4.19%)** |
| % of the 8,000,000-byte gate | 68% | 71% | +3 points |
| Headroom remaining | 2,531,904 (31.6%) | 2,303,008 (28.8%) | — |

Most of the raw delta (81%, +185 KB of the +229 KB) is quiche's own
never-loaded cdylib byproduct getting bigger at `opt-level = 3`, not a cost
of the code Android actually runs — `libvane.so` (the file
`System.loadLibrary("vane")` actually loads) grew well under 1%. The gate as
currently implemented sums both files (see `report-artifact-sizes.sh`'s own
comment: "what one device actually downloads for its ABI"), so both are
reported here; whether that byproduct should ship in `jniLibs` at all is a
separate, pre-existing packaging question out of scope for this change,
noted for the backlog, not fixed here. Gate verdict either way: **PASS**,
not pushed toward the line in any decisive way.

**iOS device** (`aarch64-apple-ios`), default features, linked `cdylib`
byproduct (the honest app-size proxy this file already uses elsewhere —
Apple links against the `.a`, so this reflects a real link + dead-code-elimination
pass, not the unlinked archive):

| File | Before | After | Delta |
|---|---:|---:|---:|
| `libvane.dylib` | 4,003,636 | 4,067,964 | +64,328 (+1.61%) |

### Verdict: KEPT

Real, directly-measured, reproducible CPU wins on both targeted packages
(QPACK -8.7%/-12.2%, SHA-256 ~2.06x) for a size cost that is small in
absolute terms on the artifact that actually matters (+0.84% `libvane.so` on
Android, +1.61% `libvane.dylib` on iOS) and does not move either device-shipping
ABI meaningfully toward the 8 MB CI gate (68% &rarr; 71%, still comfortable
headroom). `ring` was evaluated and excluded on checked evidence (its hot
paths are already assembly, not Rust `opt-level`-sensitive). The change
stays in `vane-rs/Cargo.toml`.

Gates run after the change (not committed by this pass): `cargo fmt --check`
clean; `cargo clippy --release --all-targets -- -D warnings` clean, both
default and `--no-default-features`; `cargo test --release` 64/64 default,
47/47 `--no-default-features`; `VANE_TEST_BASE_URL=https://cloudflare-quic.com
cargo run --release --example protocol_check` — ok, live.
