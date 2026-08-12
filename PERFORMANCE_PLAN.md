# Vane Performance and Feature Parity Plan

Drafted 2026-07-28 from a full audit of `vane-rs/src/lib.rs` (Rust core) and
the Flutter/Kotlin/Swift binding layers; extended the same day with the
rhttp-parity feature targets (full protocol ladder, DevTools, Dart ecosystem
adapters). Line references are as of commit `718e880`. Companion to `PLAN.md`
gate 14 (re-benchmark and size-optimize) and the "Required Feature Coverage"
table.

## Feature parity targets (rhttp checklist) — all closed 2026-08-03

The original twelve-item checklist, drawn up 2026-07-28. Every row is done; the
"status today" column it used to carry was left unrevised for two weeks while
Phases 6 and 7 landed underneath it, and by 2026-08-12 it was claiming
"HTTP/3 only" and "not implemented" about shipped features. Kept as the record
of what was promised, rewritten to say what is true.

| Target | State |
|--------|-------|
| HTTP/1, HTTP/1.1, HTTP/2, HTTP/3 | Done — `tcp-fallback` is a default feature; HTTP/1.0 responses are accepted, forcing 1.0 requests stays unsupported |
| TLS 1.2 and 1.3 | Done — rustls on the TCP path; HTTP/3 is 1.3-only by spec |
| Connection pooling | Done on both transports, default ON, with reuse-retry |
| Interceptors | Done (Swift/Kotlin/Flutter) |
| Retry (optional) | Done |
| Certificate pinning | Done on both transports, host-scoped, fail-closed; pinned hosts never resume a TLS session on either transport |
| Proxy support | Done — MASQUE/CONNECT-UDP over H3, HTTP CONNECT over TCP, from one `proxy_url` |
| Custom DNS resolution | Static overrides done on both transports; **dynamic resolver callbacks still missing** |
| Cookies | Done — one opt-in jar, both transports, public-suffix aware |
| Strong type safety | Done by construction |
| DevTools Network tab | Done (`package:http_profile`) |
| `package:http` / dio / `dart:io` compat | `http` and dio done; `dart:io` deliberately gated on a consumer needing it |

### Measured against rhttp 0.18.0 as it actually ships — 2026-08-12

The checklist above predates two weeks of rhttp releases and was always
narrower than rhttp's real surface. Compared against the published package
rather than the list, these gaps remain. Five of the seven are already named in
`PLAN.md` under "still intentionally future work" — they are deferrals, not
blind spots.

| Gap | rhttp | Vane |
|-----|-------|------|
| **Streaming response body** | `Stream<Uint8List> body` | buffered whole — the only *capability* gap; SSE and token-streaming APIs cannot be used at all |
| Mutual TLS | `TlsSettings.clientCertificate` | none |
| min/max TLS version | `minTlsVersion` | none |
| Custom root certificates | `trustedRootCertificates` | none |
| Dynamic DNS resolver | `DnsSettings.dynamic({resolver})` | static overrides only |
| Multiple / conditional proxies | `ProxySettings.list([...])`, per-scheme | one `proxy_url` |
| Configurable redirect cap | `RedirectSettings.limited(n)` | fixed at 10, on/off only |

Running the other way, and worth stating because parity talk tends to be
one-directional — Vane has, and rhttp does not (verified by source inspection,
zero hits in its `lib/`): certificate pinning of any kind, MASQUE/CONNECT-UDP
proxying, and native Kotlin and Swift APIs at all. rhttp is a Flutter package,
so "parity" is only a meaningful claim about the Dart surface.

Ground rule: every phase lands with a measurement. No change is "done" until
the number that motivated it moves (or the change is rejected on evidence).
Corollary learned the hard way, twice: a status column is a claim, and an
unrevised one is a false claim.

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

## Phase 5a — Build profile opt-level (size/speed tradeoff) — DONE 2026-07-29, KEPT

Naming collision warning: "Phase 5" ended up meaning two different things.
This one — raising `opt-level` on the hot dependencies — was never attempted,
and got lost behind the per-slice size *measurement* (Phase 5b, done
2026-07-29). It was the last unevaluated throughput lever; now evaluated and
closed. Full numbers, method, and the `ring` exclusion evidence are in
`ARTIFACT_SIZES.md` ("Phase 5a — opt-level override"); summary here.

Landed, keeping `opt-level = "z"` on the top crate:

```toml
[profile.release.package.quiche]
opt-level = 3
[profile.release.package.sha2]
opt-level = 3
```

`ring` (in the tree via rustls for `tcp-fallback`) was considered and
excluded: its hot AEAD/hash/curve primitives are hand-written assembly
(`ring-0.17.14`'s `build.rs` compiles ~90 asm/perlasm files per target arch),
compiled by `cc`/an assembler and already outside rustc's `opt-level` —
verified in the vendored source, not assumed. Same reasoning as BoringSSL's
C code (unaffected by these overrides, since it targets `quiche`'s and
`sha2`'s Rust code only).

- `examples/bench.rs` against `cloudflare-quic.com`: **no resolvable
  difference**, as flagged as a real possibility going in — RTT-dominated,
  and `bench.rs`'s unpinned default config never even calls `sha2` (that path
  only runs for `spki-pinning`/cert-DER pin checks). Reported honestly rather
  than reading noise as a win: warm pool-on p50 moved 73.3&rarr;62.2 ms
  across 3 runs/side, but the CPU delta below is a few hundred ns/request —
  five orders of magnitude too small to explain an 11 ms gap.
- Resolved instead by timing the two targeted dependencies directly
  (throwaway example, not committed, deleted after use), calling `quiche`'s
  own public QPACK codec and `sha2::Sha256::digest` with no network
  involved, 500k iters/side: QPACK encode -8.7%, QPACK decode -12.2%,
  SHA-256 (550-byte buffer, matching `sha256_pin()`'s real usage) **-51.4%
  (~2.06x)**. Real, reproducible, low run-to-run variance.
- Size, same-session before/after, default features: Android arm64-v8a
  native payload (the CI gate's sum of `libvane.so` + `libquiche-*.so`)
  5,468,096 &rarr; 5,696,992 bytes (+4.19%, 68%&rarr;71% of the 8,000,000-byte
  gate, still comfortable headroom) — but `libvane.so` itself, the file
  Android actually loads, grew only +0.84%; 81% of the raw delta is
  quiche's own never-loaded cdylib build byproduct getting bigger (its
  `crate-type` list makes Cargo build it regardless of whether vane needs
  it — a separate, pre-existing packaging question, not this change's cost,
  noted for the backlog). iOS device linked `libvane.dylib`: 4,003,636
  &rarr; 4,067,964 bytes (+1.61%). Neither device-shipping ABI is pushed
  toward its gate in a decisive way.
- Verdict: **KEPT**. Real, directly-measured CPU wins on both targeted
  packages for a size cost too small to threaten the existing budget.
- Gates: `cargo fmt --check` clean; `cargo clippy --release --all-targets --
  -D warnings` clean, both default and `--no-default-features`; `cargo test
  --release` 64/64 default, 47/47 `--no-default-features`; live
  `examples/protocol_check.rs` against `cloudflare-quic.com` — ok. Not
  committed by this pass.
- Owner: devops (measurement), cto (accept/reject call) — measured and
  recommended KEEP; size deltas are small enough that this did not need to
  escalate for a separate accept/reject call.

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
| 7.3 | dio adapter | DONE 2026-07-29: `vane_flutter_dio/` sibling package (dio 5.11, `publish_to: none` while it uses a path dependency), `VaneDioAdapter implements HttpClientAdapter`, cancelFuture → `VaneCancelToken`, 12 contract tests green. dio's three timeout budgets collapse onto vane's single whole-request deadline (largest wins). Ceilings documented: buffered upload, single-valued headers, no reason phrase. `set-cookie` and the negotiated protocol were added 2026-08-03 (multi-value list; `Response.extra['httpVersion']`), which raises the dio floor to 5.9.2 | M |
| 7.4 | `dart:io` `HttpClient` interface | Decision-gated: the full `HttpClient`/`HttpClientRequest`/`HttpClientResponse` surface is large, and 7.2+7.3 already cover the ecosystem's real entry points. Build only when a consumer actually requires the `dart:io` interface (e.g. `HttpOverrides`) | L |

- Acceptance: a request made through the `http` adapter and through dio shows
  up in DevTools Network tab with correct timings; adapter test suites pass.
- Owner: mobile-platform-dev (7.1), dev-worker (7.2, 7.3).

## Status — batch 1 landed 2026-07-28 (committed, d0d08ad)

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

## Status — batch 2 landed 2026-07-28 (committed, d0d08ad)

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

## Phase 5b done 2026-07-29 — per-slice sizes measured, size triggers amended

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

iOS app-size impact, measured 2026-07-29 (details in `ARTIFACT_SIZES.md`):
adding vane to an app costs **+1.88 MiB binary / +1.01 MiB download** on the
small profile and **+4.28 MiB / +2.34 MiB** on the full one; full minus small
is 2.40 MiB / 1.33 MiB. Linkage was verified by symbol inspection, not
assumed. The 49.8 MB `.a` overstates the real binary delta by **10.6x** and
the download delta by **19.1x** — never quote archive sizes as app impact.
The interim cdylib proxy predicted 2.25 MB against a real 2.51 MB (10%
optimistic, right order of magnitude) and is retired.

## Android: TCP fallback made real, 2026-07-29

Shipping `tcp-fallback` default-on exposed two Android-only defects that no
host test could catch. Both are fixed and covered by instrumented tests on an
API 35 emulator (5/5): HTTP/3 through the CA directory, HTTP/1.1 through the
JNI trust store, self-signed rejected, CRL-only hosts accepted, stapling host
still works.

1. `rustls_platform_verifier` needs a one-time JNI init with an Android
   `Context`. Without it the crate's `global()` panics — and the release
   profile is `panic = abort`, so an uninitialized process aborted outright
   rather than returning an error. A bare `ContentProvider` now runs the init
   at process start (public API unchanged); `tls_config` guards the single
   place a platform verifier is constructed and names the missing step.
   Upstream's Kotlin component is not on Maven Central (issue #115), so it is
   vendored — now as patched source rather than a binary jar.
2. Certificates from CAs that retired OCSP in 2025 (Let's Encrypt, Google
   Trust Services) are CRL-only, so Android's `PKIXRevocationChecker` throws
   instead of soft-failing, and the vendored verifier mapped every
   `CertPathValidatorException` to `Revoked` without reading its reason. A
   large share of the web was unreachable over TCP while
   `HttpsURLConnection` succeeded on the same device. Fixed by reporting the
   exception's reason; patch prepared for upstream #221.

Measured along the way, and it changes the threat model: **network-fetched
OCSP is already inoperative on Android.** Responder URLs are cleartext
`http://` by RFC 6960 and `usesCleartextTraffic` defaults false for targetSdk
28+, so the fetch fails and `SOFT_FAIL` forgives it — an A/B against the
upstream mapping confirms a genuinely revoked certificate connects either
way. Revocation is enforced only from a staple (which still blocks). The
HTTP/3 path performs no revocation checking at all, so the fix costs no
parity.

Also hardened: CA root loading now tries the Conscrypt APEX store first and
treats a present-but-empty directory as a miss. BoringSSL's directory load
registers a lazy lookup path and succeeds on an empty directory, which would
have yielded zero trust anchors and failed every HTTP/3 handshake with an
opaque error. (`/system/etc/security/cacerts` is populated on the API 35
emulator — 145 certs — so this is hardening, not a live bug.)

Open, not fixed: `unexpected_eof` roughly 1 in 3 against some hosts over
HTTP/1.1 — pre-existing rustls/reqwest behavior, not Android-specific; the
instrumented test retries 3× with a comment on why that cannot mask an init
regression.

## CLOSED 2026-08-03: HTTP/3 now follows redirects

Fixed by extracting the TCP path's decision functions into shared code
(`next_redirect_url`, `redirect_rewrite`, `header_survives_origin_change`,
`MAX_REDIRECTS`) rather than porting a second copy — a copy would have
re-diverged on the next edit, which is the bug itself. `tcp.rs` lost its
private copies; its `redirect_target` is now a thin adapter. Security
verified line-by-line that every rule from the three earlier TCP reviews
survived the extraction unchanged.

Two problems surfaced during review and were fixed with it:
- The chain broke the invariant behind `never_left_the_client()`. Hop N's
  handshake yields the same `ConnectTimeout` as hop 0's, but by then hop 0's
  request had been delivered and answered — so a POST that redirected could
  be replayed over the TCP fallback. The claim is now withdrawn after hop 0.
- Cross-origin body replay was refused for 307/308 only, so a 301/302 on a
  GET-with-body shipped the body to the new origin: header stripping dropped
  `Authorization` while the credential in the body went anyway. Now refused
  for any method that keeps its body. **This changed TCP behaviour too.**

Also: intermediate 3xx bodies capped at 64 KiB (a hostile chain cost ~704 MiB
on H3 and nothing on TCP), one real deadline instead of a per-stage budget
that each stage re-anchored, and a `vane-redirect-refused` header so callers
can distinguish "blocked for your safety" from "a 3xx you opted out of
following". The chain loop takes its hop executor as a closure, so it is
tested offline against a stub responder.

Deferred with a known ceiling: header-time `stream_shutdown` on a followable
hop (would avoid downloading intermediate bodies at all, but a refused hop
must still reach the caller with its body) and deferring `File::create` until
a hop is known final — residual is a ≤64 KiB redirect stub left in
`response_body_path` when a chain errors mid-way. Also still no offline HTTP/3
*server*; multi-hop wire coverage is the live pie.dev test.

## Historical — the gap as originally found 2026-07-29

`follow_redirects` is honoured only on the TCP path (`redirect_target` /
`follow_and_read` in `tcp.rs`); `lib.rs` has no `LOCATION` handling at all.
This was known as a Phase 6 behavior difference, but its consequences were
not: a request that redirects simply returns the 3xx over HTTP/3 while the
same request follows it over TCP, so **the two transports return different
things for the same URL** — and in `Http3ThenHttp2ThenHttp1` which one you get
depends on whether UDP is available.

It surfaced while hunting a live test endpoint: `/cookies/set/{n}/{v}` answers
302 on every faithful httpbin, so no correct endpoint can make
`live_http3_cookies_when_base_url_is_set` pass over H3. Options: implement
redirect following on the H3 path (real parity, and the TCP loop is a working
model to copy — including its pin/downgrade/header rules, which H3 would need
too), or relax that assertion and document the difference. Prefer the former;
transport-dependent behavior is the kind of thing that bites in production and
not in tests.

## Live test endpoints, settled 2026-07-29

`https://pie.dev` is httpbin-shaped AND HTTP/3-capable — 3 of the 4 live H3
tests pass against it (the 4th is the redirect gap above, not the endpoint).
Verified non-working: httpbin.org, httpbingo.org, httpbin.dev,
postman-echo.com (no h3); httpbun.com (advertises `alt-svc` h3, QUIC listener
refuses); nghttp2.org/httpbin (real httpbin over h3, but its path prefix
breaks `Url::join` against the tests' absolute paths).

Keep the perf baseline on `cloudflare-quic.com`: pie.dev's origin is not the
edge (warm p50 ~324 ms vs ~59 ms), so it is a correctness endpoint only, and
it carries no SLA.

## Backlog surfaced by batch-3 reviews (cross-ABI, needs core + bindings)

- ~~Surface `set-cookie` values in responses~~ — DONE 2026-08-03.
  `VaneResponse.set_cookie: Vec<String>` carries the raw final-response
  values on both transports; the C ABI reuses `VaneFfiHeaderArray` (repeated
  `("set-cookie", value)` entries, no struct growth). The TCP path also had a
  real hole: `read_body`'s skip was unconditional while the jar harvest was
  gated on `cookies_enabled`, so with the jar off `Set-Cookie` was dropped
  entirely. dio now exposes a genuine multi-value list; `package:http` gets
  the comma-joined form its own `IOClient` produces.
- Public pre-startable cancel token — **PARTIALLY** done 2026-08-03, Dart
  only. The diagnosis was one field off: `VaneCancelToken` was already
  publicly constructible and `execute`'s registration already guarded on
  `_id == null`, so a caller-held token always flowed through. The real defect
  was that `cancel()` with a null `_id` discarded the intent *forever*.
  `cancel()` now latches and `execute` replays it at registration — three
  lines of Dart, no new API, no Rust change. Fixes both adapters and the
  README example, which never cancelled anything as written.
  **Still open:** Kotlin and Swift have no cancel token at all. The UniFFI
  export list is `create_default_config`, `create_vane_client`,
  `create_progress`, `progress_snapshot_by_id`, `free_progress` and the
  `VaneClient` methods — the `vane_ffi_cancel_token_*` functions are C ABI
  only, so cancellation is reachable from Dart and from nothing else. That is
  the one place this work did not meet its acceptance bar.
- ~~Structured error kind across the FFI boundary~~ — DONE 2026-07-29.
  `VaneError` gained eight variants beside `Generic`; the dio adapter switches
  on the kind instead of substring-matching English error text, and the
  fallback rule now narrows (config failures no longer burn a TCP attempt)
  and widens (POST/PATCH fall back when the handshake never completed)
  correctly.
- ~~Negotiated protocol on `VaneResponse`~~ — DONE 2026-08-03.
  `http_version: Option<VaneHttpVersion>` — HTTP/3 is a constant on the h3
  path (the quiche config offers only `h3::APPLICATION_PROTOCOL`, MASQUE
  included), and the TCP path maps `reqwest::Response::version()` off the
  final hop. It rides the C ABI as a `u8` in the one free padding byte at
  offset 3, so the struct neither grew nor moved a field. dio now sets
  `ResponseBody.extraKeyHttpVersion`, and `examples/protocol_check.rs`
  asserts the field instead of comparing response bodies.
- ~~Repeated NON-cookie headers diverge between transports~~ — DONE
  2026-08-10. Both transports now fold response headers through one
  `ResponseState::merge_header`: repeats comma-join with `", "` in wire order
  (RFC 9110 §5.2), `set-cookie` stays exempt (list only), and a repeated
  `content-length` joins in the map while the body-reserve hint keeps
  first-value semantics. The H3 redirect gate takes the first piece of a
  joined `location` to match TCP's `.get()`. Behaviour change, shipped
  deliberately on its own; cross-transport agreement pinned by twin tests
  (offline stub on TCP, `merge_h3_header_block` unit on H3).

## Where this stands — 2026-08-10

Every numbered phase is done and committed, plus cross-ABI cancellation,
header unification, the security-audit hardening batch (ABI version guard,
progress-leak fix, body precheck, location parity, H3 header-section cap),
the in-process HTTP/3 test server, and the parser property tests.
Measured result: warm pooled p50 **114 ms → ~27 ms (−76%)** against
cloudflare-quic.com, cold ~450 ms → ~64-104 ms. The last and largest step
came 2026-08-10 from the drive-loop fix below, found only because a
cross-client benchmark exposed a 2x deficit that Vane's own before/after
numbers had hidden for months. Current suite: 103 Rust tests
all-features / 82 `--no-default-features` (offline H3 wire tests +
resumption e2e + 14 property tests), 5/5 live HTTP/3 against pie.dev,
Kotlin 17, Swift 16, dio 14, Flutter 40, size gate PASS.

The property tests earned their keep immediately, finding two real URL-parser
bugs of the same differential class as the earlier HIGH finding: a bracketed
IPv6 host kept its hex case while pin keys are stored lowercase, so an app
pinning `[2001:DB8::A]` and requesting that same spelling **connected
unpinned with no error**; and `parse_port` accepted `"+80"` because
`u16::from_str` allows a leading `+` and only the non-bracketed branch
pre-screened digits. Both fixed at the choke point, both mutation-probed.

| Phase | State |
|-------|-------|
| 0 baseline | done — `examples/bench.rs` |
| 1 latency (1.1-1.4) | done |
| 2 throughput (2.1-2.6) | done; 2.5's Dart-boundary copy deferred (needs a UniFFI record change) |
| 3 Flutter FFI (3.1-3.4) | done |
| 4 Kotlin/Swift | done — uniffi 0.31.2 landed, so Kotlin uses JNA direct mapping; 4.2/4.3 remain upstream-only |
| **5a opt-level** | **done 2026-07-29 — measured, KEPT (see above)** |
| 5b per-slice sizes | done; triggers amended by CTO |
| 6 TCP fallback | done, plus Android trust store made real |
| 7 Flutter ecosystem (7.1-7.3) | done — DevTools, `http`, dio |

Closed 2026-07-29, previously on this list: Phase 5a opt-level; uniffi
0.29.3 → 0.31.2 (Kotlin now uses JNA direct mapping); CI per-ABI size
reporting with the 8 MB gate; the structured error kind, which also fixed the
fallback rule in both directions; the `unexpected_eof` diagnosis and its fix;
the httpbin-shaped HTTP/3 endpoint hunt (pie.dev); and the iOS app-size
measurement.

Closed 2026-08-10, previously the top of this list:

1. ~~Cancellation is Dart-only~~ — `create_cancel_token`/`cancel_by_id`/
   `free_cancel_token` are now UniFFI exports sharing the C ABI trio's
   registry. Kotlin gets `VaneCancelToken : AutoCloseable` (eager native id,
   `cancel()`, volatile `isCancelled`, bridge-stubbed for JVM tests), Swift a
   final class with `deinit`-owned free; both wire through
   `VaneRequestBuilder.cancelToken(...)` into the record field that already
   existed. Eager creation removes the latch window Dart needs — Dart's token
   registers late over the platform channel, theirs exists from birth.
   Builder-only attach: convenience methods don't take a token; anyone
   needing cancel routes through `request()`.
2. ~~Repeated non-cookie headers diverge~~ — see the backlog entry above.
3. ~~Kotlin coverage for `setCookie`/`httpVersion`~~ —
   `VaneResponseFfiRoundTripTest` (7 tests) round-trips the RustBuffer wire
   format converter-by-converter in declared field order, pins the
   `VaneHttpVersion` discriminants 1-4, and was mutation-checked (swapping
   two field reads fails it). H3's `http_version: Some(Http3)` got its
   assertion in the interim-block test 2026-08-03. Still true and accepted:
   nothing links the `small` XCFramework — its staleness is caught by
   `release-build.sh` rebuilding it, not by a test.
4. Housekeeping — `make clean` in `vane-rs/Makefile` (cargo clean for the
   ~10 GB target/ plus vane-bindgen's); run it on low disk or after a
   toolchain bump, at the price of one cold build.

## The drive-loop stall — found 2026-08-10 by benchmarking against peers

The single largest latency win in the project, and it sat undetected through
every phase above because Vane was only ever measured against its own
baseline. A Dart benchmark (`vane_benchmark/`) put Vane beside rhttp, dio and
`package:http` on one endpoint and showed Vane **last in every run, ~2x
slower than rhttp at the same protocol** — about one extra RTT per request.

Cause: `read_quic_packets` ran a blocking socket with a read timeout of
`min(conn.timeout(), 50 ms)` and looped on `recv` until that timeout fired, so
the only exit from a successful read was to block for the full timer waiting
for a packet that was never coming. Every call site is ordered read-then-flush,
so the sleep sat between the response arriving and our ACKs going out.
Instrumented live: 84 of 84 packet-carrying reads ended in a 35-51 ms dead
block; a warm request was ~25 ms of real work plus one ~40 ms sleep. Cold and
pool=off paid it three times, with the server visibly cwnd-blocked waiting for
ACKs we were holding — a circular stall, not a local one.

Fix: the first `recv` still blocks on the same timer (the one legitimate wait,
which is also what bounds cancel/deadline responsiveness and keeps the loop
from spinning); after the first packet the socket flips non-blocking, drains
the burst, and blocking mode is restored before every return including error
paths. Std-only, two fcntls per burst.

Result: warm pool=on p50 **69-71 ms → 25-30 ms**, pool=off **206-208 → 49-52**,
cold **208-222 → 64-104**. Against the peers the deficit is gone and Vane now
trades places inside the field run to run; parity is what the data supports,
not a crown.

Lesson worth keeping: self-relative benchmarks certify the direction of a
change and say nothing about whether the absolute number is any good. Every
phase in this document reported honest improvements against Vane's own past
while a 40 ms structural stall sat untouched in the drive loop.

## Cross-client benchmarking — 2026-08-11, and what it cost to learn

Benchmarking against peers (`vane_benchmark/`, `vane_benchmark_ios/`,
`VaneKotlin/BENCHMARK.md`) found more real defects in a day than any
self-relative measurement had in months:

- The **drive-loop stall** above (warm H3 69 → 27 ms).
- **The Android AAR at HEAD could not load at all** — 49 undefined BoringSSL
  symbols from a poisoned boring-sys CMakeCache; a cdylib link tolerates
  undefined symbols, unit tests never load the `.so`, and the CI staleness
  gate only diffs bytes, so nothing caught it. `build_so` now ends in
  `check_so_links`.
- **Both platform artifacts shipped a stale core** for hours after the
  drive-loop fix, because rebuilding them was treated as a follow-up rather
  than part of the change. The iOS benchmark measured Vane's h3 at 75-77 ms
  and spent a full investigation blaming `--lib-type static`; the archive was
  simply two commits old. Rebuild artifacts in the same commit as a core fix.
- **Android TCP cold start at 0.87-1.07 s** against 45-200 ms for
  Cronet/OkHttp/Retrofit — closed by `warmup()` (54-100 ms after warmup).
  Diagnosing it surfaced the root disease: the vendored platform verifier
  re-runs PKIX path building and revocation on **every handshake**, ~350-400 ms
  each on Android. `warmup()` sidesteps it with session resumption; caching
  that state in the verifier is the actual fix and is still open.

Standing results, all as measured, Vane's losses included: warm p50 is a parity
band with the field on every platform. Two qualifications, both measured:
on Android HTTP/3 the 2026-08-12 `SO_RCVBUF` fix removed the packet drops
that caused Cronet's *stable* 25.8-vs-35.7 ms win, but Cronet still comes
out ahead in three runs of four (26.0-38.2 vs 25.0-32.9) with a better
p95; and on Apple platforms the p95 tail, much smaller since the QoS fix,
is still the group's worst on HTTP/1.1.

Open work, roughly by leverage:

1. ~~Vane's fat p95 tail on Apple~~ — CLOSED 2026-08-12, and the cause was
   not networking at all. The prime suspect was ruled out cold: pooled
   reuse-retry fired **zero times in ~1,800 instrumented requests**, and the
   tail did not reproduce in the Rust core or on the macOS host. It was
   `Task.detached(priority: .utility)` around every blocking FFI call in
   `VaneClient+Extension.swift`: utility sits in a low scheduler band, and on
   the TCP path the tokio reactor thread inherits that QoS from its first
   caller. A/B/A settled it — restoring `.utility` brought a 257 ms p95 back
   within one run, and whole *rounds* went slow together, which no
   per-request reconnect can produce. Fixed by routing all seven wrappers
   plus `warmup` through one GCD queue at explicit `.default` QoS (not a
   priority bump: a blocking call inside Swift's width-limited cooperative
   pool is a starvation hazard that a bump would have left in place).
   Measured: h3 p95 92-105 → 31-41 ms, max 195 → 45; h2 p95 47-52 → 35-39.
   h1 improved (p95 257 → 36-75) but stays the noisiest cell, and one 240 ms
   h2 outlier survived — the tail is much smaller, not gone. **Simulator
   only; a real device has not confirmed it**, and on-device QoS throttling
   may differ.

   Lesson, again: the obvious mechanism was the wrong one, and only
   per-request attribution could show that. The trace points used —
   DNS, pool checkout outcome, connect+resumed, retry, QUIC stall — are worth
   keeping as the observability hooks gate 5 already asks for.

2. ~~The h3 median gap to Cronet on Android~~ — CLOSED 2026-08-12, and again
   the cause was one nobody predicted. Per-request attribution split every
   request at the response-HEADERS event: TTFB was at parity or better (Vane
   23.3 ms p50 vs Cronet 30.4 in the same window), and the whole gap sat in
   body transfer (p50 8.5 vs 3.3 ms; p95 55 vs 6 ms — 3 of 30 requests
   stalled ~50 ms mid-body). The kernel named the mechanism: `Udp:
   RcvbufErrors` grew by exactly one drop per request under Vane's traffic
   (+36 in 36 requests) and by zero under Cronet's. A pooled connection
   keeps the server's congestion window hot, so each 126 KB response
   arrives as one ~111-packet burst; at ~2 KB of kernel skb accounting per
   1350-byte datagram that costs ~256 KB against Android's 224 KB default
   socket buffer, the tail of the flight is dropped at the socket, and tail
   loss is recovered by the server's probe timeout (~40-55 ms) rather than
   fast retransmit — exactly the 76-98 ms maxima the matrix kept showing.
   Fixed by requesting a 1 MB `SO_RCVBUF` (Chromium's number) on every QUIC
   UDP socket, best-effort, kernel-clamped to `rmem_max`. After: zero
   RcvbufErrors across ~216 Vane h3 requests, body p95 55 → 8-17 ms.

   **The drop mechanism is gone; the ranking is not.** Independently
   re-measured over four more runs after the fix landed: the kernel counter
   held at exactly 0 across a full run (against ~36 before), but matrix p50
   came out Vane 26.0-38.2 against Cronet 25.0-32.9 — parity in one run,
   Cronet ahead in three, with Vane's p95 still the worse of the two.
   Emulator weather is large enough to swing both clients by 10 ms, so the
   honest reading is that the ~10 ms *stable* deficit became a smaller,
   noisier one rather than closing. The residual below is the likeliest
   remaining cause and is now the open item. Host macOS A/B: unchanged within noise
   (body p50 2.9-3.6 → 3.1-5.1) — a real network paces the flight the
   emulator's userspace NAT delivers in one burst, and macOS defaults are
   larger; the knob cannot regress a clean path because `SO_RCVBUF` is a
   limit, not an allocation. Handshake count while diagnosing: 1 per run,
   35/36 requests reused the pooled connection. Residual, accepted: ~3 ms
   body-side p50 vs Cronet on the emulator from one recv syscall per
   datagram vs Cronet's GRO+recvmmsg batching — the upgrade path was
   already noted on `read_quic_packets`.
3. ~~Per-handshake PKIX cost in the vendored Android verifier~~ — CLOSED
   2026-08-12. Per-stage measurement split the ~350-400 ms in two:
   Conscrypt's trust-index build inside `checkServerTrusted` costs
   316-680 ms but only **once per process** (platform code, already absorbed
   by `warmup()`), while `PKIXBuilderParameters(keystore, null)` cost
   46-310 ms on **every** verification because its `KeyStore` constructor
   re-enumerates AndroidCAStore and re-parses every root from disk. Fixed by
   extracting the `Set<TrustAnchor>` once per process and building the
   parameters from it — `PKIXParameters(KeyStore)` does exactly that
   extraction internally, so it is equivalence, not a shortcut. **No verdict
   is cached**: expiry, path building and revocation still run per
   handshake, and the #221 CRL patch is byte-untouched. Warm-process
   non-resumed verification 291-299 ms → 29-36 ms. What remains (~15-35 ms)
   is Conscrypt path building plus revocation evaluation — platform-bound.
4. ~~TCP resumption ignores the never-resume-pinned-hosts rule~~ — CLOSED
   2026-08-12, and it was a **real pin bypass**, not just an asymmetry. A
   resumed TLS 1.3 handshake carries no Certificate message, so rustls never
   calls `verify_server_cert` where the pins live; it restores
   `peer_certificates` from the cached chain and asserts verification
   ("We *don't* reverify the certificate chain here", rustls
   `client/tls13.rs`). `tls_config` never set `ClientConfig::resumption`, so
   the default cache was live — and `warmup()` had just made it worse by
   priming tickets deliberately, so a pinned host's *first real connection*
   resumed and skipped its pin check. Demonstrated as [Full, Resumed] before
   the fix. Closed with a `PinAwareSessionStore` that refuses to store or
   offer for pinned hosts, per-host so unpinned hosts still resume, failing
   closed on an unspellable name. Pin-change invalidation already worked
   (the client is dropped wholesale) — verified rather than assumed, which
   narrowed the hole to same-pin-set resumption.

   Worth keeping: this was introduced by a performance change made the same
   day. A speed fix that touches session caching is a security change to the
   pinning path, whether or not it looks like one.
5. **Upstream PR for rustls-platform-verifier #221** — patch ready at
   `docs/upstream/`, not opened; needs a fork and is an outward-facing action.
6. ~~End-to-end session resumption~~ — CLOSED 2026-08-10 by the in-process
   HTTP/3 test server (`vane-rs/src/h3_offline.rs`, cfg(test) only): the
   server issues NewSessionTickets and records `is_resumed()` per
   connection; offline tests pin `[false, true]` for a non-pinned host and
   `[false, false]` for a pinned one. The only remaining live-infra gap is
   the MASQUE inner MTU fix under load (needs a live CONNECT-UDP proxy).
   Bonus offline coverage from the same server: `/get`+`/post` echo,
   cookie-set-on-302 readback, and a 3-hop redirect chain on the H3 wire —
   the env-gated live tests stay as-is.
7. `PLAN.md`'s release checklist still has five unticked items that all need
   real hardware: AAR from a clean CI checkout, a clean Android app on a real
   device, Swift live H3 plus a clean app import, and TLS tests on devices.
8. Emulator traps worth knowing before blaming a build: an emulator can wedge
   into a state where `adb devices` reports `device` while every shell command
   hangs (`adb kill-server` exposes it as `offline`), and Gradle will wait on
   that forever with no timeout.
Worth keeping for whoever meets it again: the `unexpected_eof` flakiness
(fixed 2026-07-29) was the hyper connection-pool checkout race — an idle
connection whose FIN has arrived but has not been processed is handed out, the
request is written to a half-closed socket, and the read returns EOF. Measured
13.3% at the race window, 0% with a single retry, 0% with pooling off, and
*identical with a clean `close_notify`* — so rustls was never the cause and
making it tolerate EOF would only have renamed the bug. hyper's own retry
cannot cover it: it retries only `Retryable`, and ours arrives as
`SendRequest` because the message was already committed. The fix was the
reuse-retry rule the H3 path had had since batch 1.
