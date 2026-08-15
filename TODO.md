# What's left

Written 2026-08-15 as a handoff. `PERFORMANCE_PLAN.md` is the plan of record and
carries the history and the reasoning; this file is only the open items and the
things you need to know before touching the build. `PLAN.md` is gitignored,
unmaintained, and cannot be read by anyone else — ignore it.

Feature-wise Vane is done: both streaming directions work in all three
bindings, and nothing on the rhttp comparison is a missing capability. What
remains is shipping, hardware validation, and knobs.

## 1. Nobody outside this machine can use Vane — publishing

The largest item, and the only one that changes who can adopt this. Every
package is a path dependency today: `vane_flutter` and `vane_flutter_dio` have
`publish_to: none`, `Package.swift` binds a local XCFramework, and the AAR is
built locally. Needs a version scheme, per-ecosystem publishing (pub.dev, Maven
Central, an SPM tag), and a decision about whether the XCFramework ships in-repo
or as a release asset. **Publishing is outward-facing — do not publish anything
without the user asking for that specific act.**

## 2. Five release-checklist items, all needing real hardware or CI

Emulator and simulator work does **not** discharge these, and this week's
numbers came from exactly there.

- [ ] Android release AAR builds from a clean checkout in CI
- [ ] Android clean app loads the AAR and does an HTTP/3 request on a real device
- [ ] Swift live HTTP/3-only GET against a confirmed HTTP/3 endpoint
- [ ] Swift clean app imports the package and does an HTTP/3 request
- [ ] TLS tests pass on real devices

Related: the Apple p95 QoS fix is simulator-verified only, and on-device QoS
throttling (Low Power Mode especially) may behave differently.

## 3. Test coverage gaps, each named deliberately

- **Abort-while-parked against the real core, in one Kotlin or Swift test.**
  The wrapper half and the core half are each proven; nothing spans both. Dart
  has such a test (`vane_flutter_ffi_test.dart`) — copy its shape.
- **Kotlin's generated FFI call sites** are unreachable from JVM unit tests
  (they cannot load the `.so`). Only `androidTest` can cover them.
- **Live upload backpressure through the wrappers** — the core proves it; the
  bindings only prove it against fakes.
- No hermetic end-to-end Dart streaming test: the core is https-only and its
  test-CA seam is `cfg(test)`-only, so a shipped dylib cannot trust a local
  server. Live tests are gated on `VANE_TEST_BASE_URL`; if CI never sets it,
  a port-protocol regression surfaces nowhere.

## 4. Config knobs — build on demand, not speculatively

Everything rhttp has that Vane does not, and none of it is a capability:
mutual TLS client certificates, min/max TLS version, custom root certificates,
dynamic DNS resolver callbacks, multiple or per-scheme proxies, configurable
redirect cap. Also open: remote IP and true list-shaped headers on the response.

## 5. Small and deferred, with reasons

- **recvmmsg/GRO batching** — worth ~3 ms against a 25 ms RTT. Measured, judged
  not worth it. Don't take it on without a profile that disagrees.
- **Upstream PR for rustls-platform-verifier** — two applicable patches sit in
  `docs/upstream/`, verified against upstream `main`. The user has said not to
  touch other repos; they stay as a record of what Vane patches locally.
- Per-handshake H3 inactivity timeout (today the whole upload must fit the
  request deadline on TCP, because reqwest wraps body-send and headers in one).
- `stream_shutdown` for the un-FINed request stream, on both paths.
- Buffered H3 uploads have never sent `content-length`; streamed ones do.

## Before you touch the build

- **A `vane-rs` change means rebuilding `VaneKotlin` and `VaneSwift` artifacts
  in the same commit.** Nothing catches staleness: unit tests never load the
  native libs and CI's gate only diffs bytes. This cost a full phantom
  investigation once already.
  ```
  cd vane-rs && make build_swift && make build_swift_small
  cd vane-rs && env ANDROID_HOME="$HOME/Library/Android/sdk" \
    ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/27.0.12077973" \
    CARGO_TARGET_DIR="$HOME/.cargo-target" make build_kotlin
  ```
- **NDK 27.0.12077973 is the CI pin.** A different NDK produces byte-different
  output and fails the staleness gate. `ANDROID_HOME` is unset in this shell —
  pass it inline, never write `local.properties`.
- **`check_so_links` runs at the end of `build_so` and must pass.** It exists
  because a poisoned boring-sys CMakeCache once produced a `libvane.so` with 49
  undefined BoringSSL symbols that could not `dlopen` at all — and it shipped,
  because a cdylib link tolerates undefined symbols. If it fires, purge
  `release/build/boring-sys-*` and `release/.fingerprint/boring-sys-*` for the
  Android targets in **both** `vane-rs/target` and `~/.cargo-target`.
- **`vane_ffi_abi_version` (currently 4) and Dart's `_expectedAbiVersion` move
  together**, on any `VaneFfi*` layout change or new exported symbol. UniFFI
  changes do not touch it — UniFFI has its own checksum guard.
- `VaneSwift/Sources/VaneSwift/VaneClient.swift` carries a hand-patch (a
  BOM-preserving UTF-8 decoder) that regeneration silently reverts. Re-apply it.
- Emulator trap: `adb devices` reporting `device` while every shell hangs means
  it is wedged — `adb kill-server` exposes it as `offline`, and Gradle waits
  forever. Use timeouts.

## How the work that went well was done

Four performance gaps and one pin bypass were closed this week. None of them
was the mechanism anyone predicted, and the method is why:

- **Measure before fixing.** The p95 tail was blamed on connection reuse; it was
  Swift QoS. The Android h3 gap was blamed on congestion control; the kernel was
  dropping packets. Aggregate percentiles say a problem exists and cannot say
  what it is — only per-request attribution can.
- **Benchmark against peers, not only against your own past.** Every phase
  reported honest self-relative wins while a 40 ms structural stall sat in the
  drive loop. It surfaced the day Vane was put beside rhttp.
- **Prove a test discriminates by writing the naive version and watching it
  fail.** Several tests here would have passed an implementation with the exact
  bug they exist to catch.
- **State which layer a test pins.** One report described a driver-level test as
  if it covered the wiring beneath it; the wiring was in fact untested.
- **Review a cross-binding design before implementing it three times.** The
  streaming design was wrong in three places, all found by building the first
  binding. That order made the errors cheap.
- **A status column is a claim.** Three docs here were asserting things that had
  stopped being true.
