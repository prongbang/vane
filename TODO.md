# What's left

Written 2026-08-15 as a handoff, item 2 and item 4½ updated 2026-08-29 after
the first real-hardware run. `PERFORMANCE_PLAN.md` is the plan of record and
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

## 2. Release checklist — the iOS half is discharged, the Android half is not

Emulator and simulator work does **not** discharge these. Run on real hardware
2026-08-29 against an iPhone 15 (iOS 26.2.1) and a PPA-LX2 (Android 10).

- [ ] **Android release AAR builds from a clean checkout in CI.** The build
      half is proven: a fresh clone with submodules produces a
      byte-size-identical AAR (7,514,739). The *CI* half is not, and cannot be
      until the commits below are pushed — CI cannot check out a tree whose
      submodule commits only exist locally. See item 4½.
- [ ] **Android clean app loads the AAR and does an HTTP/3 request on a real
      device.** Blocked, not attempted: `minSdk = 33`
      (`VaneKotlin/library/build.gradle.kts`) and the only real Android device
      here is API 29. Needs either an API 33+ device or a decision to lower
      minSdk — which is a trust-store and TLS-API question, not just a number.
- [x] **Swift live HTTP/3-only GET against a confirmed HTTP/3 endpoint.**
      Passes on the device, and on the host against `https://pie.dev`
      (`alt-svc: h3=":443"` confirmed). Shown to discriminate: pointed at a
      host with no h3 it fails at the QUIC handshake.
- [x] **Swift clean app imports the package and does an HTTP/3 request.** A
      throwaway SwiftUI app consuming VaneSwift over SPM, on the device. This
      is the check that earned its keep twice: it caught
      `VaneConfigurationBuilder` having no public initializer (no external
      consumer could configure anything at all), and then that **HTTP/3 had
      never once worked on a physical iPhone** — the platform-roots lookup was
      filesystem-based and no iOS sandbox has those paths. Both fixed.
- [~] **TLS tests pass on real devices.** iOS: 10/10 on the device, both
      transports — expired, self-signed and wrong-host chains rejected by the
      real Apple trust store, a wrong pin rejected as a pin mismatch on each
      transport, and a correct pin accepted. Android: blocked with the item
      above.

Related: the Apple p95 QoS fix is still simulator-verified only, and on-device
QoS throttling (Low Power Mode especially) may behave differently. Nothing in
the 2026-08-29 run touched it.

**The lesson worth keeping.** Every iOS number in this repo before 2026-08-29
came from the simulator, and the simulator runs on a Mac filesystem — so
`/etc/ssl/cert.pem` exists there and the HTTP/3 trust lookup silently worked.
A whole transport was broken on real hardware for the entire life of the
project, behind a green test suite. "Simulator does not discharge this" was
already written here; it turned out to be the single most load-bearing
sentence in the file.

## 3. Test coverage gaps — closed 2026-08-23

- **Abort-while-parked against the real core** — done, in Swift:
  `settlingTheRequestWhileAWriteIsParkedFreesTheRealRegistryStream`
  (`VaneUploadStreamingTests.swift`), the Dart test's shape. Mutant-verified:
  with the `onCancel` free removed it fails at the 60 s time limit (the runner
  process still wedges after the recorded issue — that is the loud signal).
- **Kotlin's generated FFI call sites** — covered by
  `VaneBodyStreamInstrumentedTest` (androidTest): checksum gate, real-registry
  create/write/finish/free, and abort-while-parked against the packaged `.so`.
  Green on the API 35 emulator; a real-device run stays under item 2.
- **Live upload backpressure through the wrappers** — covered in all three
  bindings with a progress-gauge bound (source never > 640 KiB ahead of
  `uploadSent`): Swift `streamedUploadBackpressureHoldsTheLiveSourceToTheTransportDrain`,
  Dart `'a live streamed upload never runs ahead of the transport'`, Kotlin
  `VaneUploadBackpressureLiveInstrumentedTest`. All gated on
  `VANE_TEST_BASE_URL`.
- Hermetic end-to-end Dart streaming remains impossible by design (https-only
  core, `cfg(test)`-only CA seam — unchanged). The hole it left is closed
  instead: `release.yml` now has an advisory `live` job that sets
  `VANE_TEST_BASE_URL=https://pie.dev` and runs the Swift and Dart live
  suites, so a port-protocol regression surfaces there.

## 4. Config knobs — demanded 2026-08-23, three of four batches landed

The plan of record is `docs/config-knobs-design.md` — one adversarially
reviewed design covering all eight knobs, implemented in four batches. Each
batch is one commit set spanning core + all bindings + rebuilt artifacts.

- **Batch 1 landed (`4bd77a6`)** — the whole ABI v4→v5 (config members,
  `remote_ip` slot, typed error-kind on create, DNS stub symbols; the number
  never moves again), `maxRedirects` on both transports, TLS min/max
  (enforced on TCP, validate-only on H3 — QUIC is 1.3-always).
- **Batch 2 landed (`c4e43b1`)** — responses carry ordered `(name, value)`
  pairs (duplicates preserved, set-cookie in position) plus `remoteIp` on
  both transports; first-wins `headerMap` + multimap `headerMapList` views;
  dio gets every duplicate.
- **Batch 3 landed (`3b31a7f`)** — custom roots (OR-composite verifier on
  TCP, in-memory boring ctx-builder on H3) and mTLS, behind a blocking
  security gate that failed once and forced three real fixes (peer-spoofable
  `vane-redirect-refused` header, a non-zeroizing key copy, undocumented
  revocation asymmetry). Android composite tripwire green on the API 35
  emulator.
- **Batch 4 landed (2026-08-27)** — the dynamic DNS resolver callback
  (§1f/§3f/§5 Batch 4 of the design), whole: core trait + setter draining
  the H3 pool, TLS session bank and `tcp_client`; `resolve_peer_addr` chain
  (override → resolver → system, hard errors, both transports + warmup +
  proxy); reqwest `ResolverAdapter` with the `spawn_blocking` bridge and a
  concurrency regression test pinning it; the C-ABI rendezvous filling the
  v5 stubs (10 s budget, tombstoned late replies, close-settled entries
  kept alive for still-queued listeners — nothing frees a host buffer a
  listener may read); Dart `NativeCallable.listener` plumbing +
  `VaneClient.setDnsResolver`, with the four dangerous-machinery tests
  green against the real dylib (round-trip, timeout, late-reply no-op,
  close-in-flight); Swift/Kotlin get the UniFFI foreign-trait interface,
  each with a recorded-resolver local-listener test (Swift hermetic; Kotlin
  instrumented, green on the API 35 emulator — the listener must bind
  127.0.0.1 explicitly, `getLoopbackAddress` gave ::1). All four artifact
  sets rebuilt in the same commit.
- Per-scheme/multi proxies resolved as documented-no-change in the design
  (§1e); nothing further to build.

Still open after batch 4: nothing in this item. The knobs' remaining risk
lives in item 2 — every new instrumented test has run on the emulator only.

## 4½. Blocked on the user: nothing is pushed

Re-checked 2026-08-29 after `git fetch`. The five commits touching
`.github/workflows/` that triggered the original PAT-scope rejection are no
longer outgoing, so that specific blocker may already be gone — **untested**,
because pushing is the user's call, not something to try and find out.

What is outgoing now, all from 2026-08-29 and none of it touching
`.github/workflows/`:

| Repo | Unpushed |
|---|---:|
| superrepo | 4 |
| VaneSwift | 3 |
| vane-rs | 2 |
| VaneKotlin | 2 |
| vane_flutter | 1 |

This is what blocks the CI half of item 2: a clean checkout from GitHub fails
immediately with `not our ref` on the submodule commits. If the PAT still
rejects the push, fix one of: add the `workflow` scope (then
`git credential-osxkeychain erase` the stale entry), or register
`~/.ssh/id_ed25519.pub` with the GitHub account and switch the remote to SSH.

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
