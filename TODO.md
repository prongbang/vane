# What's left

Written 2026-08-15 as a handoff. Item 2 was rewritten 2026-08-29 after the
Android half finally ran on real hardware; items 3, 4 and 4½ were corrected in
the same pass, where they had been asserting things that had stopped being
true. `PERFORMANCE_PLAN.md` is the plan of record and
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

## 2. Release checklist — four of five discharged on real hardware

Emulator and simulator work does **not** discharge these. First real-hardware
run 2026-08-29 against an iPhone 15 (iOS 26.2.1) and a PPA-LX2 (Android 10);
the Android half was blocked that day and ran later the same day, once
`minSdk` dropped to 29 (`dab5e88`) and the device stopped being unusable.

- [~] **Android release AAR builds from a clean checkout in CI.** The
      clean-checkout half is **done**: `git clone --recurse-submodules` from
      GitHub, then `:library:assembleRelease`, produces 7,514,743 bytes —
      byte-identical to the working tree. (That number predates `dab5e88`,
      which added `androidx.annotation` to the AAR; re-baseline it on the next
      clean-checkout run.) The *CI* half is the last open box in this item.
      `Release Verification` had failed on every run in its history, at
      `Verify release build`, for three independent reasons found and fixed
      2026-08-29:
      1. clippy 1.93 denies `vane_ffi_client_create` (fixed, pushed).
      2. `flutter analyze` fails on two stale platform mocks (fixed, pushed).
      3. **The release job never installed Flutter at all**, so
         `scripts/release-build.sh` exited 127 after ~26 minutes. Fixed in
         `dcf78d7`, which **is now on `origin/main`** — item 4½'s description
         of it as unpushable is stale.
      The run on `1b5a98d` was the first in the workflow's history to get past
      `Set up Flutter`, and **`Verify release build` passed** on it, in 40
      minutes. Two more failures followed, both now fixed:
      4. `Verify generated artifacts are current` — reached for the first time
         ever, and failed. Not stale artifacts: `make build_swift` was not
         reproducible, so `git diff --exit-code` could never pass. `libtool`
         stamped every ar member header with the current time, and a trailing
         `xcrun strip -S -x` re-stamped `__.SYMDEF` after it. Object code was
         identical throughout — 912 members, not one differing byte. Fixed in
         `1cf699a`: strip per object, `libtool -D` last. Android was already
         reproducible and needed nothing.
      5. `Check out repository` — the `62d033b` run died before running
         anything, because two submodule pointers on `main` referenced commits
         that existed only locally. Pushed; a fresh
         `git clone --recurse-submodules` from GitHub now resolves all four.
      **The box stays open until a run reports success.** Note that CI's Xcode
      and rustc are not pinned to any developer's, so cross-machine byte
      equality of the archives is still unproven — reproducibility on one
      machine was necessary, not obviously sufficient.
- [x] **Android clean app loads the AAR and does an HTTP/3 request on a real
      device.** Done on the PPA-LX2 (Android 10, API 29, arm64-v8a). A
      throwaway app that consumes only `library-release.aar` as a `files()`
      dependency — no project module wiring, and every transitive dependency
      named by hand, which is what an external adopter actually faces. It
      declares neither `INTERNET` nor `VaneInitProvider`; both arrive by
      manifest merging from the AAR, and the merged manifest was checked
      rather than assumed. Two `http3Only()` GETs returned
      `status=200 version=HTTP3` (cloudflare-quic.com 125,959 B, pie.dev 418
      B). Shown to discriminate: the same config against `example.com`, which
      advertises no h3, fails at `QUIC connection closed before handshake
      completed` instead of falling back to TCP.
- [x] **Swift live HTTP/3-only GET against a confirmed HTTP/3 endpoint.**
      Passes on the device, and on the host against `https://pie.dev`
      (`alt-svc: h3=":443"` confirmed). Shown to discriminate: pointed at a
      host with no h3 it fails at the QUIC handshake. Re-run 2026-08-29 in the
      clean-app harness below — 200/HTTP3 against both cloudflare-quic.com and
      pie.dev, with the no-h3 control still rejected.
- [x] **Swift clean app imports the package and does an HTTP/3 request.** A
      throwaway SwiftUI app consuming VaneSwift over SPM, on the device. This
      is the check that earned its keep twice: it caught
      `VaneConfigurationBuilder` having no public initializer (no external
      consumer could configure anything at all), and then that **HTTP/3 had
      never once worked on a physical iPhone** — the platform-roots lookup was
      filesystem-based and no iOS sandbox has those paths. Both fixed.
- [x] **TLS tests pass on real devices.** iOS: 11/11 on the iPhone 15, both
      transports — expired, self-signed and wrong-host chains rejected by the
      real Apple trust store, a wrong pin rejected as a pin mismatch on each
      transport, and a correct pin accepted on each. Android: 20/20 on the
      PPA-LX2 for the whole non-benchmark instrumented suite, including the
      five cases added in `68b0dc9` to close a coverage asymmetry the earlier
      tick would have hidden — Android had no pinning test at all, so the box
      did not mean the same thing on the two platforms.

      One gap, stated rather than papered over: **correct-pin-accepted over
      HTTP/3 is not covered on Android.** The local test server speaks TLS
      over TCP, not QUIC, and the only alternative is pinning a live rotating
      leaf — a test that passes today and fails on renewal. The iOS device run
      covers that case and the pin code path underneath is shared Rust.

Related: the Apple p95 QoS fix is still simulator-verified only, and on-device
QoS throttling (Low Power Mode especially) may behave differently. Nothing in
the 2026-08-29 runs touched it.

**The lesson worth keeping.** Every iOS number in this repo before 2026-08-29
came from the simulator, and the simulator runs on a Mac filesystem — so
`/etc/ssl/cert.pem` exists there and the HTTP/3 trust lookup silently worked.
A whole transport was broken on real hardware for the entire life of the
project, behind a green test suite. "Simulator does not discharge this" was
already written here; it turned out to be the single most load-bearing
sentence in the file.

**The second lesson, from the Android half.** That half sat blocked for weeks
behind `minSdk = 33`, recorded as a trust-store and TLS-API question. It was
neither: the number was an Android Studio template default, the shipped
`libvane.so` had always targeted API 21, and the one real blocker was UniFFI
generating an unguarded `java.lang.ref.Cleaner` call. Building at 29 and
reading the three lint errors took minutes and answered a question that
reasoning about it had not. A blocker nobody has tried to reproduce is a
guess.

## 3. Test coverage gaps — closed 2026-08-23

- **Abort-while-parked against the real core** — done, in Swift:
  `settlingTheRequestWhileAWriteIsParkedFreesTheRealRegistryStream`
  (`VaneUploadStreamingTests.swift`), the Dart test's shape. Mutant-verified:
  with the `onCancel` free removed it fails at the 60 s time limit (the runner
  process still wedges after the recorded issue — that is the loud signal).
- **Kotlin's generated FFI call sites** — covered by
  `VaneBodyStreamInstrumentedTest` (androidTest): checksum gate, real-registry
  create/write/finish/free, and abort-while-parked against the packaged `.so`.
  Green on the API 35 emulator and, since 2026-08-29, on a real PPA-LX2
  (Android 10, API 29).
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

Still open after batch 4: nothing in this item. The emulator-only caveat that
used to sit here is discharged: the whole non-benchmark instrumented suite,
batch 3's composite tripwire and batch 4's recorded-resolver test included,
ran 20/20 on a real PPA-LX2 on 2026-08-29.

## 4½. Was blocked on the user — the workflow commit did land

Re-checked 2026-08-29 against `origin`, not against this file's memory of it.
`dcf78d7` **is on `origin/main`**; `git branch -r --contains dcf78d7` names it
and the Flutter setup step is present in `origin/main:.github/workflows/release.yml`.
Whatever the PAT could not do earlier, this commit is no longer waiting on it.

That leaves nothing blocked on the user here. The only thing still owed is a
`Release Verification` run that actually reports success — tracked in item 2,
not here.

Keep the remedy written down in case the rejection returns on the next
workflow edit: add the `workflow` scope to the PAT (then
`git credential-osxkeychain erase` the stale entry), or register
`~/.ssh/id_ed25519.pub` with the GitHub account and switch the remote to SSH.

## 5. Small and deferred, with reasons

- **recvmmsg/GRO batching** — worth ~3 ms against a 25 ms RTT. Measured, judged
  not worth it. Don't take it on without a profile that disagrees.
- **Upstream PR for rustls-platform-verifier** — two applicable patches sit in
  `docs/upstream/`, verified against upstream `main`. The user has said not to
  touch other repos; they stay as a record of what Vane patches locally.
- ~~Per-handshake H3 inactivity timeout~~, ~~`stream_shutdown` for the
  un-FINed request stream~~, ~~buffered H3 uploads never sent
  `content-length`~~ — all three landed 2026-08-30, core + all three bindings
  + rebuilt artifacts in one change-set. The timeout became an opt-in knob
  (`inactivity_timeout_seconds`, ABI v6) rather than a change of meaning for
  `timeout_seconds`: it replaces the absolute deadline rather than layering
  on it, so with it set nothing caps a request's total duration. Unset —
  every existing caller — behaviour is unchanged.

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
- **Two Android devices are usually attached** — the PPA-LX2 (`CNXNU21106102415`,
  Android 10 / API 29 / arm64-v8a) and an emulator. Gradle runs
  `connectedAndroidTest` on *both* unless you pass
  `ANDROID_SERIAL=CNXNU21106102415`, and a green run on the wrong one is
  exactly the kind of claim item 2 exists to prevent. Skip the benchmarks with
  `-Pandroid.testInstrumentationRunnerArguments.notPackage=com.inteniquetic.vanekotlin.benchmark`
  and feed the live upload test with
  `-Pandroid.testInstrumentationRunnerArguments.VANE_TEST_BASE_URL=https://pie.dev`
  (a runner argument — the env var never crosses to the device).
- **`flutter test` picks a different dylib than every build writes.** The Dart
  tests look for `vane-rs/target/release/libvane.dylib` — the crate-local
  target dir — while `release-build.sh` and the commands above all build into
  `CARGO_TARGET_DIR=$HOME/.cargo-target`. A stale copy in the crate-local dir
  is therefore preferred over the one you just built, and since it is
  gitignored nothing flags it. It surfaces as the ABI guard firing
  (`native libvane ABI v5, this package expects v6`), which reads like a bug
  and is the guard working. Pass
  `VANE_TEST_LIBRARY=$HOME/.cargo-target/release/libvane.dylib`.
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
