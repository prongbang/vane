# Vane Performance and Feature Parity Plan

Drafted 2026-07-28 from a full audit of `vane-rs/src/lib.rs` (Rust core) and
the Flutter/Kotlin/Swift binding layers; extended the same day with the
rhttp-parity feature targets (full protocol ladder, DevTools, Dart ecosystem
adapters). Line references are as of commit `718e880`. Companion to `PLAN.md`
gate 14 (re-benchmark and size-optimize) and the "Required Feature Coverage"
table.

## Feature parity targets (rhttp checklist)

| Target | Status today | Covered by |
|--------|--------------|------------|
| HTTP/1, HTTP/1.1, HTTP/2, HTTP/3 | HTTP/3 only | Phase 6 (TCP fallback backend); HTTP/1.0 accepted on responses only, forcing 1.0 requests stays unsupported |
| TLS 1.2 and 1.3 | TLS 1.3 only (QUIC mandates 1.3) | Phase 6 — rustls on the TCP path does 1.2+1.3; HTTP/3 stays 1.3-only by spec |
| Connection pooling | Implemented for H3, default ON since batch 1 (with reuse-retry: a pooled connection that fails before the first response byte is discarded and retried once on a fresh connection) | Done for H3; TCP pool comes free with the Phase 6 client |
| Interceptors | Implemented (Swift/Kotlin/Flutter) | Done — no plan item |
| Retry (optional) | Implemented | Done — no plan item |
| Certificate pinning | Implemented for H3 | Phase 6 extends the same host-scoped pins to the TCP path via a custom rustls verifier |
| Proxy support | MASQUE/CONNECT-UDP for H3 | Phase 6 adds HTTP CONNECT proxying for the TCP path from the same `proxy_url` |
| Custom DNS resolution | Static overrides for H3 | Phase 6 maps the same overrides onto the TCP client; dynamic callbacks stay future work |
| Cookies | Implemented (opt-in jar) | Phase 6 routes TCP responses through the same jar — one jar, both transports |
| Strong type safety | Rust core + typed bindings | Done by construction — no plan item |
| DevTools Network tab | Not integrated | Phase 7.1 (`package:http_profile`) |
| `package:http` / dio / `dart:io` compat | Not implemented | Phase 7.2-7.4 |

Ground rule: every phase lands with a measurement. No change is "done" until
the number that motivated it moves (or the change is rejected on evidence).

## Phase 0 — Baseline measurement (do first)

Without a baseline, none of the wins below can be proven.

- Add a tiny env-gated bench binary (`vane-rs/examples/bench.rs`): N sequential
  GETs + one large download against `VANE_TEST_BASE_URL`, printing p50/p95
  latency and MB/s. No framework, ~60 lines.
- Record: cold first-request latency, warm request latency (pool on/off),
  10 MB download throughput, peak RSS.
- Owner: qa-tester. Effort: S.

## Phase 1 — Request latency, Rust core (biggest user-visible wins)

| # | Change | Where | Effort |
|---|--------|-------|--------|
| 1.1 | Send the H3 request before the first socket read; the current order blocks up to 50 ms in `recv` before the request leaves | `perform_http3_request`, `lib.rs:1657-1667` | S |
| 1.2 | Build `quiche::Config` once per client instead of per connection — today `load_platform_roots` re-reads the CA bundle (on Android: the whole `/system/etc/security/cacerts` directory) on every connect | `create_quiche_config`, `lib.rs:1728`, `lib.rs:1749` | M |
| 1.3 | Flip `connection_pool_enabled` default to `true` (full QUIC handshake per request today) | `lib.rs:363` | S |
| 1.4 | TLS session resumption: store `conn.session()` per host after handshake, `set_session()` on reconnect. Resumption only — do NOT enable 0-RTT (replay risk) | new, near `connect_quic_h3` | M |

Notes:
- 1.2 caveat: `set_max_idle_timeout` is per-`Config`; cache per timeout value
  and rebuild only when the effective timeout changes.
- 1.3 is a behavior change — document idle UDP sockets on mobile
  backgrounding/network transitions; keep the opt-out.
- Acceptance: warm p50 latency drops vs Phase 0 baseline; live tests still pass.
- Owner: tech-lead.

## Phase 2 — Transfer throughput and CPU, Rust core

| # | Change | Where | Effort |
|---|--------|-------|--------|
| 2.1 | Hoist hot-loop buffers (64 KB + 16 KB + 1.35 KB memset per drive-loop iteration) into `PooledHttp3Connection`/`H3ResponseState` | `lib.rs:2197`, `lib.rs:2305`, `lib.rs:2234`, `lib.rs:1521`, `lib.rs:1458` | M |
| 2.2 | Resolve cancel/progress ids to `Arc` handles once per request; per-chunk cost becomes one relaxed atomic op instead of two global mutex locks per 16 KB | `lib.rs:1989`, `lib.rs:2324`, `lib.rs:2328` | S |
| 2.3 | `reserve_exact` response body from the already-parsed `content-length` header (capped by `max_response_body_bytes`) | `H3ResponseState`, `lib.rs:2274`, `lib.rs:2292` | S |
| 2.4 | Re-arm `set_read_timeout` only when the computed timeout changes (currently a setsockopt syscall every read call) | `lib.rs:2192-2195` | S |
| 2.5 | `request.body.take()` instead of `.clone()`; skip the extra `.to_vec()` copy at the Dart FFI boundary (call is synchronous, a borrow suffices) | `lib.rs:1972`, `lib.rs:2725` | S |
| 2.6 | MASQUE: shrink the inner connection's `max_send_udp_payload_size` to ~1200 so full-MTU inner packets + varint framing fit the outer H3 DATAGRAM limit (currently both are 1350 → oversized datagrams fail at high throughput) | `lib.rs:1000-1004`, `create_quiche_config` | M |

Deferred with a known ceiling: streaming upload from file (today the whole
body is buffered in RAM, capped at 64 MB). Add when large-upload use cases
appear; `send_body` already chunks, so the change is localized to
`load_request_body` and `H3RequestOptions`.

- Acceptance: 10 MB download throughput up, CPU time per transfer down,
  MASQUE upload no longer errors at full MTU.
- Owner: tech-lead (2.6), dev-worker (rest).

## Phase 3 — Flutter FFI

| # | Change | Where | Effort |
|---|--------|-------|--------|
| 3.1 | Replace per-request `Isolate.run` with one persistent worker isolate (SendPort queue). Today every request pays isolate spawn + `DynamicLibrary.open` + 12 dlsym lookups, because Dart statics are per-isolate. Must keep the injected-library test path working | `vane_flutter/lib/vane_flutter_ffi.dart:246`, `:350` | M |
| 3.2 | Fix the use-after-free in `_VaneFfiString.value` (returns a struct view over freed calloc memory) by writing fields directly into the destination struct; also removes ~30 malloc/free pairs per request. Correctness first, perf second | `vane_flutter_ffi.dart:728-737` and call sites `:524-702` | S |
| 3.3 | Zero-copy response body: `Pointer.asTypedList(len, finalizer:)` over the buffer Rust already hands over via `mem::forget` (needs a tiny Rust free-shim with pointer-arg signature). Decode header strings straight off the view (no Rust change) | `vane_flutter_ffi.dart:500`, `:488-494`; `vane-rs/src/lib.rs:2992` | M |
| 3.4 | `isLeaf: true` on trivial FFI calls (`progress_snapshot` is polled every 100 ms per transfer); NOT on `vane_ffi_execute` (blocking) | `vane_flutter_ffi.dart:306-348` | S |

- Acceptance: small-request round-trip time from Dart drops (3.1 dominates);
  large-response memory copies drop to zero on the Dart side.
- Owner: mobile-platform-dev.

## Phase 4 — Kotlin / Swift bindings

Status 2026-07-28: hand-written-file items landed (shared `Json`/`prettyJson`
instances in `VaneClient.kt`, shared `JSONDecoder`/`JSONEncoder` in
`VaneClient+Extension.swift`; swift test 14/14 and gradle :library:test pass).
Two audit items were closed as invalid on evidence: Kotlin `.toList()` already
returns the `EmptyList` singleton for empty lists (no guard needed), and lazy
`text` caching is impossible from hand-written code because `VaneResponse` is a
generated data class/struct (needs a generator-level stored field).

Remaining items live in UniFFI-generated code (repo is on uniffi 0.29.3):

| # | Change | Route | Effort |
|---|--------|-------|--------|
| 4.1 | Kotlin JNA direct mapping | Bump uniffi to **0.31.2** — direct mapping is unconditional since 0.30.0 (no flag, no patch step). 0.31.2 specifically fixes direct-mapped `u8`/`u16` returns on ARM32 Android and a `FfiConverterString` BOM-stripping bug. Skip 0.32.0: it silently ignores the flat `--config uniffi.toml` that `vane-bindgen/generate.sh` passes (wrong Kotlin package on regen). Kotlin+Swift regeneration must land in the same PR as the bump (CI checks staleness). Note: removes proxy/reflection overhead but the per-call clone crossing remains | M |
| 4.2 | Swift `FfiConverterData/String.read` triple copy | Unfixed upstream through 0.32; no local hook (`cargo swift package` owns generation) — upstream PR (`subdata(in:)`, ~4-line template change) or drop | S (PR) |
| 4.3 | Kotlin `toUtf8` CharsetEncoder per string | Unfixed upstream through 0.32. Plain `toByteArray(UTF_8)` would CHANGE lone-surrogate semantics (REPORT → replacement char) — if Phase 0 numbers ever justify it, use a `ThreadLocal` cached encoder via the existing post-gen step in `generate.sh`; otherwise do nothing | S |

Deferred: exposing the `#[repr(C)]` typed-FFI response path (the one Flutter
uses — currently the fastest binding) to Kotlin/Swift for `execute_request`
only. Revisit if benchmarks show UniFFI serialization still dominates large
payloads after 4.1.

- Owner: dev-worker (done items); tech-lead owns the uniffi 0.31.2 bump.

## Phase 5 — Build profile (size/speed tradeoff, evidence-gated)

- Per-package override, keeping `opt-level = "z"` on the top crate:

```toml
[profile.release.package.quiche]
opt-level = 3
[profile.release.package.sha2]
opt-level = 3
```

- BoringSSL C code is compiled by `cc` with its own flags and is unaffected;
  this targets quiche's Rust packet/QPACK code.
- Process: build all slices, record deltas in `ARTIFACT_SIZES.md`, keep only if
  the throughput gain justifies the size growth per the existing size budget.
- Owner: devops (measurement), cto (accept/reject call).

## Phase 6 — TCP fallback backend: HTTP/1.1 + HTTP/2 + TLS 1.2/1.3 (feature)

Reintroduces the removed TCP fallback. An earlier draft of this plan proposed
`ureq`; that was dropped when the parity targets grew to include HTTP/2 and
pinning-on-TCP: ureq is HTTP/1.1-only and exposes neither the peer certificate
nor a custom TLS verifier hook, so it cannot satisfy the checklist and would
have been throwaway work. The backend is `reqwest` (blocking client,
`default-features = false`, features `rustls-tls`, `http2`, `blocking`) — the
same engine rhttp ships on mobile, so the size and behavior envelope is known.

Why reqwest specifically covers every gap in one dependency:
- HTTP/1.1 + HTTP/2 via ALPN; HTTP/1.0 responses accepted by hyper.
- TLS 1.2 and 1.3 via rustls.
- Certificate pinning: `ClientBuilder::use_preconfigured_tls` accepts our own
  rustls `ClientConfig`, where a custom `ServerCertVerifier` runs standard
  webpki verification first, then enforces Vane's host-scoped
  `sha256/<spki>` and `sha256-cert/<der>` pins. Same pin store, same
  fail-closed semantics as the H3 path — PLAN.md gate 15's "pinning cannot be
  bypassed by fallback transport" holds by construction, not by refusing
  fallback.
- Custom DNS: `ClientBuilder::resolve(host, addr)` maps `dns_overrides`
  one-to-one, preserving SNI/authority exactly like the H3 path.
- Proxy: `reqwest::Proxy` gives HTTP CONNECT proxying for the TCP path. The
  single `proxy_url` config is interpreted per transport: MASQUE/CONNECT-UDP
  over H3, CONNECT over TCP. Document the split.
- Its own TCP connection pool per client.

Design decisions (locked unless overridden):
- Cargo feature `tcp-fallback`, in default features (the "full production
  profile"); `make build_swift_small` builds with `--no-default-features`, so
  the small H3-only artifact is unaffected. If measured size is unacceptable
  for the default profile, demote to opt-in — CTO call on the numbers.
- Mode mapping — every `VaneProtocolMode` case becomes real:
  `Http3ThenHttp2ThenHttp1` = H3 first, TCP (ALPN h2/http1.1) on transport
  error; `Http2ThenHttp1` = TCP with ALPN; `Http2Only` =
  `http2_prior_knowledge()`; `Http1Only` = `http1_only()`.
- Reuse existing machinery: cookie jar (TCP responses feed
  `store_response_cookies`), retry loop (generalize `execute_with_retry` over
  an attempt closure), progress/cancel in the body read loop, body limits,
  `follow_redirects`. One blocking `reqwest::Client` per `VaneClient`, built
  lazily on first TCP use (keeps H3-only apps from paying the tokio runtime
  spin-up).
- Zero FFI/binding changes: `VaneProtocolMode` already exists across UniFFI,
  C ABI, Dart, Kotlin, Swift.
- Known ceiling: sequential H3-then-TCP can take up to 2× timeout when H3 is
  down. Happy-eyeballs-style racing is future work, noted in code.
- Size: measure and record in `ARTIFACT_SIZES.md` before/after (expect several
  MB per slice from tokio + hyper + rustls; this is the feature's price and
  the reason the small profile exists).
- Tests: mode-dispatch unit tests for all five modes; pin-mismatch-over-TCP
  test; env-gated live H1/H2 tests reusing `VANE_TEST_BASE_URL` (httpbin-style
  endpoints speak both).
- Owner: tech-lead (transport wiring + rustls verifier), security-engineer
  (verifier + proxy review before merge — the custom `ServerCertVerifier` is
  the security-critical piece), qa-tester (live tests).

## Phase 7 — Flutter ecosystem parity

| # | Change | Notes | Effort |
|---|--------|-------|--------|
| 7.1 | DevTools Network tab via `package:http_profile` | Record request/response events (method, headers, timings, body sizes) from the Dart layer, the same mechanism `cronet_http`/`cupertino_http` use. Pure Dart-side change in `vane_flutter` | M |
| 7.2 | `package:http` adapter | `VaneHttpClient extends http.BaseClient` implementing `send()` → `StreamedResponse`. Unlocks most of the pub.dev ecosystem | S-M |
| 7.3 | dio adapter | DONE 2026-07-29: `vane_flutter_dio/` sibling package (dio 5.11, `publish_to: none` while it uses a path dependency), `VaneDioAdapter implements HttpClientAdapter`, cancelFuture → `VaneCancelToken`, 12 contract tests green. dio's three timeout budgets collapse onto vane's single whole-request deadline (largest wins). Ceilings documented: buffered upload, single-valued headers, no reason phrase, no `set-cookie` | M |
| 7.4 | `dart:io` `HttpClient` interface | Decision-gated: the full `HttpClient`/`HttpClientRequest`/`HttpClientResponse` surface is large, and 7.2+7.3 already cover the ecosystem's real entry points. Build only when a consumer actually requires the `dart:io` interface (e.g. `HttpOverrides`) | L |

- Acceptance: a request made through the `http` adapter and through dio shows
  up in DevTools Network tab with correct timings; adapter test suites pass.
- Owner: mobile-platform-dev (7.1), dev-worker (7.2, 7.3).

## Status — batch 1 landed 2026-07-28 (uncommitted, pending human review)

Measured with `examples/bench.rs` against `https://cloudflare-quic.com`
(release builds, same machine/network, before = pre-batch baseline):

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| cold first request | 316-451 ms | 279-295 ms | improved |
| warm, pool on, p50 | 114-115 ms | 67-68 ms | **-40%** |
| warm, pool off, p50 | 317-326 ms | 266 ms | -16% |

Done: Phase 0 (bench tool + baseline); 1.1, 1.2, 1.3 (with reuse-retry);
2.2, 2.3 (capped at 1 MiB reserve after review), 2.4, 2.5 (Cow hoist;
Dart-boundary `to_vec` deferred — needs a UniFFI record change); 3.1
(persistent worker isolate — single worker serializes concurrent requests,
`ponytail:` comment in code, upgrade path = small worker pool), 3.2 (UAF
fixed), 3.4; Phase 4 hand-written items (shared Json/JSONDecoder; two audit
items closed as invalid — see Phase 4 section). Bonus from review round:
`download_total` now populated from `content-length` (download progress
totals work for the first time).

Adversarial review round fixed 4 real findings before close: quiche
`send_request` StreamBlocked/StreamLimit retry restored, 64 MB bodiless-
response pre-allocation capped, progress atomics ordering (Release/Acquire),
pool reuse-retry rule. Verification: `cargo fmt --check` / `clippy
--all-targets -- -D warnings` / `cargo test` 37/37; `flutter test` 15/15;
`swift test` 14/14; `gradlew :library:test` pass. Live tests against
cloudflare-quic.com: transport-level pass; 3 tests fail on httpbin-shaped
paths (`/get`, `/cookies/*`) that endpoint does not serve — a confirmed
httpbin-style HTTP/3 endpoint is still needed (matches PLAN.md known risk).

## Status — batch 2 landed 2026-07-28 (uncommitted, pending human review)

Done: 1.4 TLS session resumption (ticket reuse only, NO 0-RTT; pinned hosts
never resume — a resumed session restores the CACHED peer cert chain, so pin
checks would silently pass against stale certs; sessions keyed by
host+port+proxy-hop; store bounded at 8; pin changes drop the host's
sessions), 2.1 buffer hoist (recv buffer sized 2×MAX_DATAGRAM_SIZE after
review — idle pool footprint ~160 KB at 8 idle connections), 2.6 MASQUE inner
MTU (computed from outer dgram capacity minus varint framing, clamped ≥1200
before it reaches the config-cache key; framing math pinned by test), 3.3
zero-copy response body (worker returns raw response pointer; main isolate
parses; body is a native view freed by NativeFinalizer via
vane_ffi_response_free — 2 copies → 0), Flutter worker pool (cap 4,
least-busy, spawn-on-demand; worker death detected via onExit/onError, fails
pending requests fast and respawns — no permanent hangs), internal
dispose() for tests.

Review round 2 (adversarial) found 0 critical / 4 warnings, all fixed:
worker-death hang, unbounded config cache keyed on a per-connection
measurement, session-store key missing port/hop identity, oversized idle
recv buffers.

Verification: cargo test 41/41, clippy -D warnings clean, no exported ABI
changes across both batches; flutter test 19+1 offline and 20/20 with live
HTTP/3; bench after batch 2: cold ~279 ms, warm pool-on p50 62-70 ms
(baseline 114), pool-off p50 ~262 ms. Resumption's latency effect is not
visible at this endpoint (PSK saves cert bytes + verify CPU, not an RTT —
0-RTT is deliberately off); end-to-end resumption and MASQUE MTU behavior
still need a live NewSessionTicket-issuing server / MASQUE proxy to confirm.

Remaining: uniffi 0.31.2 bump (Phase 4.1 — pending task chip), Phase 5
(size/opt-level measurement), Phase 6 (reqwest TCP fallback — lib.rs is now
free), Phase 7 (DevTools + http/dio adapters).

## Status — batch 3 landed 2026-07-29 (committed)

Phase 6 (TCP fallback) and Phase 7.1/7.2 (DevTools, `package:http` adapter)
shipped. Three adversarial security rounds plus two correctness rounds ran
against the TCP path before merge; the findings and their fixes are in the
`vane-rs` commit message. Two of the HIGH findings were pre-existing bugs
affecting HTTP/3 as well (cookie `Domain` accepting a public suffix, and a
URL-parser differential that made pin/header/cookie decisions about a host
the HTTP client never connected to) — both fixed at the root, so the H3
`:authority`/SNI path is hardened too.

CTO rulings (both two-way doors, one-line reverts):
- `tcp-fallback` stays DEFAULT-ON. An H3-only default fails closed on every
  UDP-blocking network, which is a correctness failure for a general-purpose
  client, not a size trade; the small profile is the size lever. Confirmed
  after Phase 5 measured the cost at 2.30 MiB on arm64-v8a (60% of budget).
- `psl` is a DEFAULT FEATURE the small profile drops (same precedent as
  `spki-pinning`), not an unconditional dependency. The cheap guard (Domain
  must contain a dot; no Domain on IP-literal origins) ships in BOTH
  profiles; psl layers public-suffix rejection on top. Small-profile cookie
  posture is a tested fact, not a documented claim.

Verification: cargo test 60/60 (default) and 45/45 (`--no-default-features`),
clippy `-D warnings` both configs, shipping dependency tree for the small
profile contains zero TCP/psl crates, no exported ABI change across all three
batches. `flutter test` 34 offline / 37 live. Live HTTP/3: transport tests
pass; the three httpbin-shaped tests still fail on cloudflare-quic.com by
endpoint mismatch. Bench after batch 3: cold ~262 ms, warm pool-on p50
**58.7 ms** (baseline 114 ms, −49%), pool-off p50 ~260 ms.
`examples/protocol_check.rs` asserts h2 is genuinely negotiated — added
because ALPN was silently absent and no unit test could catch it (every mode
returns 200 over HTTP/1.1).

Remaining: uniffi 0.31.2 bump (Phase 4.1 — task chip pending), Phase 5
per-slice size measurement (now the gate on the CTO revisit triggers, top
priority before the next tagged release), Phase 7.3 dio adapter (separate
`vane_flutter_dio` package), Android JNI `rustls_platform_verifier::android::
init_with_env` wiring in VaneKotlin (TCP fails closed there without it), and
the cross-ABI backlog below.

## Phase 5 done 2026-07-29 — measured, and the size triggers were amended

Real builds (NDK 28.2, cargo-ndk 4.1.2, Xcode 26.1.1) against committed main.
Per-feature cost, isolated: `tcp-fallback` **+2.30 MiB** on Android arm64-v8a
and ~1.63 MiB on iOS device; `psl` ~540-565 KB per slice; `spki-pinning`
~5 KB (BoringSSL is already linked via quiche regardless — the old note
claiming the small profile saved size by dropping the SPKI parser was
wrong, and `ARTIFACT_SIZES.md` is corrected).

Measurement trap worth remembering: XCFramework `.a` deltas said
`tcp-fallback` cost +23.6 MB. A `.a` is unlinked object code with no
dead-code elimination — the linked `.dylib` byproduct of the same build
gives +1.71 MB, matching Android. Never quote `.a` sizes as app impact.

**The AAR trigger fired and was retired as the wrong metric.** The AAR sums
four ABIs; App Bundle delivers one per device, and ~55% of its native bytes
were emulator-only. Replacement, per CTO:
- **Trigger: >8,000,000 bytes uncompressed native payload on a
  device-shipping ABI** (arm64-v8a or armeabi-v7a). arm64-v8a is at
  5,451,992 — ~47% headroom, roughly one more `tcp-fallback`-sized addition.
- Unchanged: isolated `tcp-fallback` >4 MB on a device-shipping ABI, or a
  TCP-path security regression without a quick fix.
- Secondary smoke alarm only, NOT a demotion trigger: published AAR >20 MB →
  audit contents for accidental payload.
- If the payload trigger fires, re-run per-feature attribution and demote the
  largest *optional* contributor — which may not be `tcp-fallback`.

32-bit x86 is dropped from the release AAR (closes `PLAN.md` gate 11);
x86_64 stays because removing it breaks `System.loadLibrary` at RUNTIME on
Intel-host emulators, most cloud CI, and ChromeOS. Re-add x86 on any real
consumer report.

iOS has no trigger and no measurement of record: the 49.8 MB `.a` is an
unlinked archive, not app impact. The number nobody has taken — archive a
minimal SwiftUI app against the default vs small XCFramework and compare
thinned arm64 `.ipa`. Interim posture: the linked cdylib proxy stands.

## Backlog surfaced by batch-3 reviews (cross-ABI, needs core + bindings)

- Surface `set-cookie` values in responses: both transports divert them into
  the cookie jar and never expose them, so `package:http` auth libraries see
  no session header through the adapter. Needs `VaneFfiResponse` + UniFFI
  record + both transports; documented as an adapter ceiling meanwhile.
- Public pre-startable cancel token: the http adapter's `Abortable` wiring
  cannot cancel the native side in the window before the token registers
  (request runs to completion, response discarded — contract still holds).
  Needs a public API to create/register a token before execute. Both the
  `http` and dio adapters hit this.
- Structured error kind across the FFI boundary: `VaneError` is one opaque
  `Generic(String)`, so the dio adapter classifies timeouts by substring-
  matching the core's English error text ("handshake timed out" →
  connectionTimeout, etc.). A `kind` discriminant on the error record would
  make that robust — and would also let the H3 path distinguish transport
  failures from config failures, which currently costs one wasted TCP
  fallback attempt (noted in the Phase 6 ponytail comments).
- Negotiated protocol on `VaneResponse`: no field reports HTTP/1.1 vs h2 vs
  h3. dio 5.11's `ResponseBody.extraKeyHttpVersion` is left unset because of
  it, and `examples/protocol_check.rs` has to infer the protocol from
  response body length. Pairs with the "HTTP version, remote IP, multi-value
  headers" response-metadata item already in `PLAN.md`.

## Ordering and expected impact

| Order | Item | Impact | Risk |
|-------|------|--------|------|
| 1 | Phase 0 baseline | enables everything | none |
| 2 | 1.1 send-before-read, 2.2 lock hoist, 2.3 reserve, 2.4 setsockopt, 2.5 body copies | high, all small diffs | low |
| 3 | 1.2 config cache, 1.3 pool default, 1.4 resumption | high (cold + warm latency) | medium (behavior change 1.3) |
| 4 | 3.1 worker isolate, 3.2 UAF fix | high for Flutter | low |
| 5 | 2.1 buffer hoist, 2.6 MASQUE MTU, 3.3 zero-copy body | medium-high | medium |
| 6 | Phase 4 Kotlin/Swift | medium | low |
| 7 | Phase 5 opt-level | medium, size-gated | low (revertable) |
| 8 | Phase 6 TCP fallback (reqwest) | protocol/TLS/proxy/pinning parity | medium-high |
| 9 | Phase 7 Flutter ecosystem (DevTools, http, dio) | adoption | low-medium |
| 10 | Re-run Phase 0, update `ARTIFACT_SIZES.md` + PLAN.md gate 14 | proof | none |

Items 2 and 4 are safe to land in one PR each; nothing in them changes public
behavior. Item 3 changes a default and needs a changelog note.
