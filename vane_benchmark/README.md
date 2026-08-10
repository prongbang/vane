# vane_benchmark

Cross-client HTTP latency benchmark: **vane** (native FFI), **vane via the dio
adapter**, **rhttp** (pinned to HTTP/3, and at its default), **dio**'s own
dart:io adapter, and **package:http** — all in one Dart process, against one
endpoint, sequentially, so the numbers are directly comparable.

Repo-internal tooling (`publish_to: none`). It exists so the competing
clients (rhttp, dio, http) never touch the shipping packages' dependency
graphs — do not add them to `vane_flutter` or `vane_flutter_dio`.

## Run it

```sh
# 1. Build the two native cores (once, or after bumping either):
(cd ../vane-rs && cargo build --release)   # libvane
tool/build_rhttp.sh                        # librhttp, from the pub cache

# 2. Run, pointing at an HTTP/3-capable https origin:
VANE_TEST_BASE_URL=https://cloudflare-quic.com flutter test test/benchmark_test.dart
```

Without `VANE_TEST_BASE_URL` the test prints a skip message and passes, same
as every live-gated test in this repo. Without `librhttp` the rhttp rows are
skipped (with a message); the rest still run. Knobs:
`VANE_BENCH_ROUNDS` (3), `VANE_BENCH_REQUESTS` per round (10),
`VANE_BENCH_WARMUP` (5), `VANE_TEST_LIBRARY` / `RHTTP_TEST_LIBRARY` to point
at specific dylibs.

It is a `flutter test` harness, not `dart run`, because `vane_flutter`'s
platform interface imports Flutter; the test runs on the host Dart VM and
does real network I/O.

## What it measures

Per client: one **cold** request on a fresh client (reported alone), then
warmup requests (discarded), then rounds × requests **measured** sequential
GETs of `<base>/`. `p50`/`p95` are nearest-rank over the pooled measured
samples — the same formula as `vane-rs/examples/bench.rs`, so the two
benches read the same way.

Fairness measures:

- The visiting order rotates by one each round, so no client systematically
  rides a warmer network path.
- DNS for the host is resolved once before any client runs, so the first
  client's cold number is a handshake, not a resolver-cache miss.
- Status validation, byte materialization and timing are done identically in
  the harness for every client.
- Connection pooling / keep-alive is ON for every client (each one's
  default — that is how all of them ship).
- The **protocol column is what each response reported** (`VaneResponse.
  httpVersion`, dio's `extraKeyHttpVersion`, rhttp's `HttpResponse.version`).
  `package:http` cannot report one; its row is marked `*` and stated from
  dart:io's documented behavior (HTTP/1.1 only).

## Results as measured on 2026-08-10, on one machine

macOS 26.5.1 (Apple Silicon), Dart 3.12.1 / Flutter 3.44.1, residential
network, `https://cloudflare-quic.com` (~126 KB HTML). One of three
back-to-back runs; the ranking was identical in all three:

```
client                    proto  cold_ms   p50_ms   p95_ms   min_ms   max_ms        n    bytes
vane (ffi)               HTTP/3   226.79    62.85    72.41    57.52    77.19       30   125959
vane (dio adapter)       HTTP/3   251.41    69.71    76.60    62.98    80.96       30   125959
rhttp (h3)               HTTP/3   323.11    30.01    56.17    23.14    59.34       30   125959
rhttp (default)          HTTP/2    58.85    26.42    31.19    22.24    31.54       30   125959
dio (dart:io)          HTTP/1.1    74.64    27.82    31.57    24.50    32.07       30   125961
package:http          HTTP/1.1*    63.35    30.99    34.80    25.89    35.75       30   125961
```

Across the three runs, warm p50 spreads were: vane 61.9–68.5, vane/dio
61.7–69.7, rhttp-h3 28.0–30.0, rhttp-default 25.6–26.4, dio 27.7–34.8,
http 30.6–32.5 (ms).

What the numbers say, including where Vane loses:

- **Vane's warm HTTP/3 path is the slowest in the field on this endpoint —
  about 2x rhttp at the same protocol** (~62–69 ms vs ~28–30 ms p50, ~+1
  RTT per request). This is a vane-rs core finding, not a bindings one: the
  pure-Rust `vane-rs/examples/bench.rs` measures p50 65.7 ms against the
  same endpoint, matching this harness. Windows are not the ceiling (quiche
  is configured with 1 MB stream / 10 MB connection); the suspect is the
  core's event-loop cadence. Tracked as follow-up work.
- **The dio adapter adds no overhead distinguishable from network noise**:
  raw FFI and the adapter swapped places between runs (±7 ms band overlap).
- **Vane's cold start beats rhttp's at the same protocol** (~215–252 ms vs
  ~317–332 ms), with the caveat below about what each side's cold includes.
- HTTP/3 shows no warm-latency win over HTTP/2 or HTTP/1.1 here: to a
  nearby CDN edge over a good network, warm requests are RTT-bound and all
  TCP clients cluster at ~26–35 ms. HTTP/3's structural advantages
  (1-RTT/0-RTT setup, no head-of-line blocking, connection migration) are
  about lossy links and connection churn, which this bench does not model.

## Caveats a skeptical reader should raise

- **This is not a vendor benchmark claim.** One machine, one network, one
  endpoint, one payload size, sequential requests, RTT-dominated. It exists
  to catch regressions and place Vane honestly among its peers, not to
  produce a marketing number.
- Protocols differ by design — that is the point of the comparison — so
  compare like with like: vane vs rhttp-h3 is the meaningful head-to-head;
  the dart:io rows show what a stock Flutter app gets.
- Cold numbers are single samples and not fully symmetric: vane creates its
  native client lazily inside the first request, while rhttp's client is
  created before timing starts; rhttp's cold still includes its in-process
  resolver's first lookup. Treat cold as indicative only.
- The endpoint's body differs by a few bytes between protocols (the page
  echoes the negotiated protocol); payloads are equal in all but name.
- rhttp-h3 uses `http3_prior_knowledge` (no Alt-Svc round trip), the
  symmetric peer to vane's `http3Only` default. rhttp-default negotiates
  HTTP/2 — included so rhttp is also shown at the config its users run.
- `flutter test` runs debug-JIT Dart. The warmup phase absorbs JIT, and
  both Rust cores are release builds, but Dart-side per-request overhead is
  JIT-flavored for every client equally.

## rhttp integration notes

rhttp ships its Rust core as source and normally builds it via cargokit
inside a Flutter app build. On the host VM the harness instead dlopens a
cargo-built dylib: `tool/build_rhttp.sh` builds the exact rhttp version from
`pubspec.lock` out of the pub cache, with `RUSTFLAGS="--cfg
reqwest_unstable"` — the same flag rhttp's own build tool sets, required by
reqwest's `http3` feature. The harness then calls the generated
`RustLib.init(externalLibrary: …)` directly (an implementation import),
because `Rhttp.init()` only knows the bundled-library loader.
