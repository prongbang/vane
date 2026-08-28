# H3 Defer-DNS-to-Dial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop every pooled HTTP/3 request from paying a blocking `getaddrinfo` whose result is discarded — resolve the peer address only when a hop actually dials.

**Architecture:** `execute_http3_hop` (vane-rs/src/lib.rs:2020) currently calls `resolve_peer_addr` at line 2042, *before* `take_pooled_connection` (line 2083). On a pooled hit the resolved address is never used: `remote_ip` already comes from `transport.peer_addr` (the connection's own peer, lines 2150–2154), and the TLS session key needs only the URL port (line 2164). The single real consumer is `connect_http3` (line 2093), which runs only in the `None` (fresh-dial) arm. The fix moves the resolution into that arm and threads the URL port through a local. One function, both hop modes (buffered and streaming share `execute_http3_hop`); the warmup path (lib.rs:1895) and the MASQUE proxy path (lib.rs:2342) always dial, so they stay as they are.

**Why:** Measured on this host (2026-08-28, three paired A/B runs with a short-circuiting `dns_override`): warm pooled h3 p50 dropped 17.79→16.18, 17.35→16.26, 17.13→16.32 ms — 0.8–1.6 ms per request against a 1.9 ms h3-vs-h2 gap. `getaddrinfo` also carries a fat tail (p99 7.7 ms, max 13–78 ms measured) that lands in p95. Expected larger on Android, where the resolver is a Binder round trip to netd (vane h3 20.3 ms vs Cronet 18.9 in the 2026-08-28 emulator matrix).

**Tech Stack:** Rust (vane-rs core only — no ABI, UniFFI, or binding-source change). Artifact rebuild is still mandatory: a vane-rs change ships silently stale without same-commit-set jniLibs + XCFramework rebuilds (TODO.md "Before you touch the build").

**Spec:** `PERFORMANCE_PLAN.md` (plan of record; this plan adds its finding there in Task 3). Finding provenance: the 2026-08-28 h3-speedup audit — five-reader sweep, the DNS-before-pool asymmetry confirmed independently by four readers and A/B-measured by one.

## Global Constraints

- **Same-commit-set artifact rule:** any vane-rs change ⇒ rebuild `VaneKotlin` jniLibs AND both `VaneSwift` XCFrameworks in the same commit set (TODO.md:117–126).
- **NDK pin:** Android build uses NDK `27.0.12077973`, `ANDROID_HOME` passed inline, never write `local.properties` (TODO.md:127–129).
- **`check_so_links` must pass** at the end of `build_so` (TODO.md:130–135).
- **No ABI change:** `vane_ffi_abi_version` stays 5; nothing in this plan touches `VaneFfi*` layouts or exported symbols.
- **Swift hand-patch:** this plan does NOT regenerate Swift bindings (no API change), so `VaneClient.swift` is untouched. If you regenerate anyway, re-apply the BOM-preserving decoder patch (TODO.md:139–140).
- **Behavior contract that must survive:** `dns_overrides` → installed resolver → system, hard errors, resolver never silently skipped *on a dial*; `set_dns_resolver` still drains the pool (its existing test pins that).
- **Commit messages** end with `Co-Authored-By:` per repo convention (see `git log`).

## File Structure

- Modify: `vane-rs/src/lib.rs` — `execute_http3_hop` only (~10 changed lines around 2036–2101 and 2164).
- Modify: `vane-rs/src/h3_offline.rs` — one new test in the existing `mod dns_resolver` (added 2026-08-27, near end of file).
- Modify: `PERFORMANCE_PLAN.md` — one new dated section (Task 3).
- Rebuilt, not edited: `VaneKotlin/library/src/main/jniLibs/**`, `VaneSwift/RustFramework.xcframework`, `VaneSwift/RustFramework.small.xcframework`.
- Created: `vane_benchmark/results/2026-08-28-host-dns-after-pool.json` (Task 3).

---

### Task 1: Move the resolution into the dial arm, pinned by a failing pool test

**Files:**
- Modify: `vane-rs/src/lib.rs:2042-2047` (delete), `:2088-2101` (resolve in the `None` arm), `:2164` (port from URL)
- Test: `vane-rs/src/h3_offline.rs` (append inside `mod dns_resolver`, after `set_dns_resolver_drains_the_h3_pool`)

**Interfaces:**
- Consumes: `RecordingResolver` (`crate::tests::RecordingResolver`, `answering(&[&str]) -> Arc<Self>`, `calls() -> Vec<String>`), `TestH3Server` (`start()`, `url(&str)`, `handshakes() -> Vec<bool>`), `VaneClient::set_dns_resolver(Option<Arc<dyn VaneDnsResolver>>)` — all exist today.
- Produces: no new interfaces. `execute_http3_hop`'s signature is unchanged; later tasks only rebuild and measure.

- [ ] **Step 1: Write the failing test**

Append inside `mod dns_resolver` in `vane-rs/src/h3_offline.rs` (it already imports `TEST_HOST`, `TestH3Server`, `RecordingResolver`, `VaneClient`, `VaneClientConfig`, `VaneDnsResolver`, `test_request`, `Arc`):

```rust
        #[test]
        fn a_pooled_h3_request_never_consults_the_resolver() {
            let server = TestH3Server::start();
            // Pooling ON (the default): the second request must ride the
            // pooled connection, and a pooled request has no dial — so it
            // has nothing to resolve.
            let client = VaneClient::new(VaneClientConfig {
                timeout_seconds: Some(10),
                ..VaneClientConfig::default()
            })
            .unwrap();
            let recording = RecordingResolver::answering(&["127.0.0.1"]);
            client.set_dns_resolver(Some(recording.clone() as Arc<dyn VaneDnsResolver>));

            assert!(client.execute(test_request(&server.url("/get"))).unwrap().is_success);
            assert!(client.execute(test_request(&server.url("/get"))).unwrap().is_success);

            assert_eq!(server.handshakes().len(), 1, "the second request must reuse the pool");
            assert_eq!(
                recording.calls(),
                vec![TEST_HOST.to_string()],
                "resolution belongs to the dial, not the request"
            );
        }
```

- [ ] **Step 2: Run it to verify it fails for the right reason**

```bash
cd vane-rs && cargo test --features tcp-fallback a_pooled_h3_request_never_consults_the_resolver
```

Expected: FAIL on the `recording.calls()` assertion with two entries (`["h3.test", "h3.test"]`) and the `handshakes` assertion passing — proving the request pooled but resolved anyway. If `handshakes` fails instead, stop: pooling isn't engaging and the test is measuring the wrong thing.

- [ ] **Step 3: Move the resolution**

In `vane-rs/src/lib.rs`, `execute_http3_hop`:

3a. Replace lines 2042–2047:

```rust
        let peer_addr = resolve_peer_addr(
            host,
            url.port_or_known_default().unwrap_or(443),
            &self.config.dns_overrides,
            self.dns_resolver_snapshot().as_deref(),
        )?;
```

with just the port (the session key at the end of the hop needs it):

```rust
        let origin_port = url.port_or_known_default().unwrap_or(443);
```

3b. In the pool match (lines 2088–2101), resolve inside the `None` arm — the only consumer of the address. Replace:

```rust
            let mut transport = match pooled {
                Some(connection) => connection,
                None => self
                    .connect_http3(
                        host,
                        peer_addr,
                        hop.timeouts,
                        pool_key.clone(),
                        certificate_pins,
                    )
                    .inspect_err(|_| {
                        self.drop_closed_connections();
                    })?,
            };
```

with:

```rust
            let mut transport = match pooled {
                Some(connection) => connection,
                None => {
                    // Resolved here, not at hop entry: a pooled request has
                    // no dial and must not pay (or consult) the resolver —
                    // remote_ip reports the connection's own peer and the
                    // session key needs only the URL port. Measured at
                    // 0.8–1.6 ms per pooled request on the host getaddrinfo.
                    let peer_addr = resolve_peer_addr(
                        host,
                        origin_port,
                        &self.config.dns_overrides,
                        self.dns_resolver_snapshot().as_deref(),
                    )?;
                    self.connect_http3(
                        host,
                        peer_addr,
                        hop.timeouts,
                        pool_key.clone(),
                        certificate_pins,
                    )
                    .inspect_err(|_| {
                        self.drop_closed_connections();
                    })?
                }
            };
```

3c. Line 2164 — the session key read `peer_addr.port()`, which no longer exists in this scope. Replace:

```rust
                        &TlsSessionKey::origin(host, peer_addr.port()),
```

with:

```rust
                        &TlsSessionKey::origin(host, origin_port),
```

(`resolve_peer_addr` always returns the port it was handed, so `peer_addr.port()` was always exactly `origin_port` — same value, no behavior change.)

3d. `cargo check --features tcp-fallback` and fix any remaining use of the deleted `peer_addr` binding in this function — the compiler is the checklist here. Do NOT touch the resolve at lib.rs:1895 (warmup — always dials) or lib.rs:2342 (proxy — already dial-only).

- [ ] **Step 4: Run the new test, then the resolver group, to verify green**

```bash
cd vane-rs && cargo test --features tcp-fallback a_pooled_h3_request_never_consults_the_resolver && cargo test --features tcp-fallback dns
```

Expected: the new test PASSES; every existing `dns`/`resolver` test still passes — in particular `set_dns_resolver_drains_the_h3_pool` (drain still forces re-resolution) and `the_dns_resolver_steers_the_h3_transport` (a dial still resolves).

- [ ] **Step 5: Full suite + format**

```bash
cd vane-rs && cargo fmt --check && cargo test --features tcp-fallback --lib 2>&1 | tail -3
```

Expected: fmt clean, `test result: ok`. (Known pre-existing clippy failure at `vane_ffi_client_create` is out of scope — do not fix it here.)

- [ ] **Step 6: Commit vane-rs**

```bash
cd vane-rs && git add -A && git commit -m "perf: H3 resolves the peer only when it dials

A pooled request has no dial: remote_ip already reports the connection's
own peer and the session key needs only the URL port, so the hop-entry
getaddrinfo was pure waste — measured at 0.8-1.6 ms of the 1.9 ms
h3-vs-h2 steady-state gap on the host, with a 7-78 ms tail. The pool test
pins that the second request consults the resolver zero times.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Rebuild the native artifacts and re-verify the bindings (same commit set)

**Files:**
- Rebuild: `VaneSwift/RustFramework.xcframework`, `VaneSwift/RustFramework.small.xcframework`, `VaneKotlin/library/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libvane.so`
- Modify: none by hand.

**Interfaces:**
- Consumes: Task 1's committed vane-rs HEAD.
- Produces: the artifact binaries later commits and Task 3's benchmark load.

- [ ] **Step 1: Rebuild both Swift XCFrameworks**

```bash
cd vane-rs && make build_swift && make build_swift_small
```

Expected: both finish; `git -C ../VaneSwift status --short` shows ONLY `RustFramework*` paths modified — `Sources/` untouched (no API change, nothing regenerated into the package source; the `cargo swift` temp dir is deleted by the Makefile).

- [ ] **Step 2: Rebuild the Android jniLibs**

```bash
cd vane-rs && env ANDROID_HOME="$HOME/Library/Android/sdk" \
  ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/27.0.12077973" \
  CARGO_TARGET_DIR="$HOME/.cargo-target" make build_kotlin
```

Expected: ends with `check_so_links: ... ok` for all three ABIs. If `check_so_links` fires, follow TODO.md:130–135 (purge the poisoned boring-sys build dirs in BOTH target dirs) before retrying. `git -C ../VaneKotlin status --short` shows only `jniLibs` (and possibly a regenerated-but-identical `Vane.kt`; if `Vane.kt` shows a diff, inspect it — this change must not alter bindings).

- [ ] **Step 3: Swift test suite against the rebuilt framework**

```bash
cd VaneSwift && swift test 2>&1 | tail -3
```

Expected: all tests pass (31+ as of 2026-08-28), including `VaneDnsResolverTests` — its single-request shape dials, so it still resolves.

- [ ] **Step 4: Dart real-library tests against the rebuilt core**

```bash
cd vane-rs && cargo build --features tcp-fallback && cd ../vane_flutter && flutter test test/vane_flutter_ffi_test.dart 2>&1 | tail -3
```

Expected: all pass, including the four `DNS resolver rendezvous` tests (each uses one request per client — dial path, unaffected).

- [ ] **Step 5: Commit the artifact set**

```bash
cd VaneSwift && git add -A && git commit -m "build: archives rebuilt on the dial-time-DNS core

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
cd ../VaneKotlin && git add -A && git commit -m "build: jniLibs rebuilt on the dial-time-DNS core

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(vane_flutter has no change: the Dart package loads the locally built dylib in tests and carries no binary.)

---

### Task 3: Measure, record in the plan of record, commit the superrepo set

**Files:**
- Create: `vane_benchmark/results/2026-08-28-host-dns-after-pool.json` (copy of the run's `latest.json`)
- Modify: `PERFORMANCE_PLAN.md` (new dated section at the end)

**Interfaces:**
- Consumes: Task 2's rebuilt artifacts and committed submodules.
- Produces: the measured verdict; nothing downstream.

- [ ] **Step 1: Re-run the host benchmark matrix**

```bash
cd vane-rs && cargo build --release && cd ../vane_benchmark && VANE_TEST_BASE_URL=https://cloudflare-quic.com flutter test test/benchmark_test.dart 2>&1 | tail -45
```

Expected: `vane (ffi, h3)` p50 lands ~16–17 ms (2026-08-28 baseline was 18.58; the A/B predicts 16.2–16.5), within ~0.5 ms of `vane (ffi, h2)`, and no h1/h2 row regresses. **If h3 p50 does not drop by at least ~0.8 ms, stop and investigate before writing any claim** — network drift between runs is real; re-run once to confirm before concluding either way.

- [ ] **Step 2: Keep the dated result**

```bash
cp vane_benchmark/results/latest.json vane_benchmark/results/2026-08-28-host-dns-after-pool.json
```

- [ ] **Step 3: Record the finding in the plan of record**

Append to `PERFORMANCE_PLAN.md` (match its dated-section style; adjust numbers to what Step 1 actually printed):

```markdown
## H3 steady state: DNS moved to the dial — 2026-08-28

The h3-vs-own-h2 steady-state gap (~1.5–2 ms p50 on all three platforms)
was never attributed until the 2026-08-28 audit ran per-phase A/Bs: every
h3 hop resolved the peer BEFORE the pool lookup (`lib.rs:2042`) and threw
the answer away on a pooled hit — remote_ip reports the connection's own
peer, and the session key needs only the URL port. The reqwest path never
paid this: hyper resolves inside its connector, only on a fresh dial.

Fix: the resolution now lives in the dial arm of the pool match. A/B on
the host (dns_override short-circuit, three paired runs): pooled p50
17.79→16.18, 17.35→16.26, 17.13→16.32 ms. Post-fix benchmark: h3 p50
<fill from step 1> vs h2 <fill> (was 18.58 vs 17.45). The pool test
`a_pooled_h3_request_never_consults_the_resolver` pins the property.

Still open, priced and parked by the same audit: 0-RTT early data
(~1 RTT on warm-cold reconnects — a security-gated change, not a perf
patch), max_ack_delay 25 ms default (tail-only, needs observed loss),
recvmmsg/GRO (Android large bodies only, refused once already). The
remaining h3 budget after this fix is a few hundred microseconds —
vane h3 minus DNS measured at parity with curl h2 on the same network.
```

- [ ] **Step 4: Commit the superrepo set**

```bash
git add vane-rs VaneSwift VaneKotlin PERFORMANCE_PLAN.md \
  vane_benchmark/results/2026-08-28-host-dns-after-pool.json docs/superpowers/plans/2026-08-28-h3-defer-dns-to-dial.md
git commit -m "perf: H3 stops resolving on pooled requests — the steady-state gap closes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

Push only if the user asks (the superrepo push may still be PAT-blocked per TODO item 4½; submodule pushes work).

- [ ] **Step 5 (optional, advisory): Android emulator matrix**

Only if asked or if the host number disappoints — the Android delta (vane 20.3 vs Cronet 18.9) is where this fix predicts the biggest win, but it costs an emulator boot:

```bash
VANE_TEST_BASE_URL=https://cloudflare-quic.com VaneKotlin/bench-android.sh
```

Expected: vane h3 p50 moves toward Cronet's; keep the dated JSON beside the others if the run is worth recording.

---

## Self-Review

- **Spec coverage:** the finding (hop-entry resolve before pool) maps to Task 1; the same-commit artifact rule to Task 2; measure-before-claiming and the plan-of-record convention to Task 3. The audit's other levers are deliberately out of scope and recorded as such in Task 3's plan-of-record text.
- **Placeholders:** the two `<fill from step 1>` slots in Task 3 Step 3 are intentional measurement blanks the executor fills from the run they just did — not unknown design.
- **Type consistency:** `origin_port: u16` defined in Task 1 Step 3a, consumed in 3b/3c; `RecordingResolver`/`TestH3Server` names match the existing test module verbatim (checked against `h3_offline.rs` as of `2955737`).
