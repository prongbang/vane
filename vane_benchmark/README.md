# vane_benchmark

Client × protocol HTTP latency matrix: **vane** (native FFI), **vane via the
dio adapter** and **rhttp** each pinned to HTTP/1.1, HTTP/2 and HTTP/3;
**dio**'s dart:io adapter and the separate **dio_http2_adapter**; and
**package:http** — all in one Dart process, against one endpoint,
sequentially, so every comparison is like-for-like at the same protocol.

Repo-internal tooling (`publish_to: none`). It exists so the competing
clients (rhttp, dio, dio_http2_adapter, http) never touch the shipping
packages' dependency graphs — do not add them to `vane_flutter` or
`vane_flutter_dio`.

## Run it

```sh
# 1. Build the two native cores (once, or after bumping either):
(cd ../vane-rs && cargo build --release)   # libvane — default features; the
                                           # h1/h2 rows need tcp-fallback
tool/build_rhttp.sh                        # librhttp, from the pub cache

# 2. Run, pointing at an origin that serves h1.1, h2 and h3:
VANE_TEST_BASE_URL=https://cloudflare-quic.com flutter test test/benchmark_test.dart
```

Without `VANE_TEST_BASE_URL` the test prints a skip message and passes, same
as every live-gated test in this repo. Without `librhttp` the rhttp rows are
skipped (with a message); the rest still run. Knobs:
`VANE_BENCH_ROUNDS` (3), `VANE_BENCH_REQUESTS` per round (10),
`VANE_BENCH_WARMUP` (5), `VANE_TEST_LIBRARY` / `RHTTP_TEST_LIBRARY` to point
at specific dylibs. At the defaults the matrix is 12 measured rows ×
36 requests = 432 requests ≈ 15 s of network time; one `flutter test`
invocation lands around 30–45 s wall clock.

It is a `flutter test` harness, not `dart run`, because `vane_flutter`'s
platform interface imports Flutter; the test runs on the host Dart VM and
does real network I/O.

## The matrix

| client | HTTP/1.1 | HTTP/2 | HTTP/3 |
|---|---|---|---|
| vane (ffi) | `http1Only` | `http2Only` | `http3Only` |
| vane (dio adapter) | same three modes via the adapter's `VaneClient` | | |
| rhttp | `HttpVersionPref.http1_1` | `.http2` | `.http3` |
| dio (dart:io) | native | — no h2 in dart:io | — no h3 adapter exists |
| dio (http2 adapter) | | `dio_http2_adapter` | |
| package:http | native | — h1.1 only | — h1.1 only |

The pinnings are symmetric where it matters: vane's TCP path maps
`http1Only` → reqwest `http1_only()` and `http2Only` →
`http2_prior_knowledge()`, exactly the calls rhttp's `http1_1`/`http2`
prefs make; vane's `http3Only` and rhttp's `http3`
(`http3_prior_knowledge()`) both dial QUIC directly with no Alt-Svc round
trip. Cells that cannot exist are printed as `unsupported` in the output —
that Vane covers all three columns with one API and the Dart-native clients
do not is itself a result. dio's HTTP/2 comes from a separate first-party
package whose default behavior is to *silently fall back to dart:io
HTTP/1.1* when the server does not ALPN h2; the harness disables that
fallback so a pinned cell fails loudly instead of measuring the wrong
protocol.

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
- Row names state the **pinned config**; the proto column is **what each
  response reported** (`VaneResponse.httpVersion`, dio's
  `extraKeyHttpVersion`, rhttp's `HttpResponse.version`). `package:http`
  cannot report one; its row is marked `*` and stated from dart:io's
  documented behavior (HTTP/1.1 only). A row that negotiates something
  other than its pin gets a NOTE line; a pinned cell that cannot reach its
  protocol is an ERROR row, never a substituted config.
- Output is grouped **by protocol first** — the like-for-like table is the
  primary view — with a combined all-rows table after it for cross-protocol
  reading within one client.

## Results as measured on 2026-08-10, on one machine

macOS 26.5.1 (Apple Silicon), Dart 3.12.1 / Flutter 3.44.1, residential
network, `https://cloudflare-quic.com` (~126 KB HTML). One of three
back-to-back runs (the second); cross-run spreads below:

```
== HTTP/1.1 ==
client                    proto  cold_ms   p50_ms   p95_ms   min_ms   max_ms        n    bytes
vane (ffi, h1)         HTTP/1.1    75.81    25.06    29.25    20.08    34.24       30   125961
vane (dio, h1)         HTTP/1.1    69.61    24.86    33.69    19.80    33.93       30   125961
rhttp (h1.1)           HTTP/1.1   104.15    25.36    29.48    22.88    35.35       30   125961
dio (dart:io)          HTTP/1.1    80.00    24.99    28.64    22.27    29.17       30   125961
package:http          HTTP/1.1*    54.77    25.55    30.28    23.42    32.13       30   125961

== HTTP/2 ==
client                    proto  cold_ms   p50_ms   p95_ms   min_ms   max_ms        n    bytes
vane (ffi, h2)           HTTP/2    59.94    24.03    28.68    19.02    31.72       30   125959
vane (dio, h2)           HTTP/2    74.89    24.37    29.52    19.77    50.56       30   125959
rhttp (h2)               HTTP/2    59.12    25.29    30.70    21.31    32.80       30   125959
dio (http2 adapter)      HTTP/2    96.62    46.15    92.42    39.07    94.54       30   125959
dio (dart:io)            unsupported: dart:io has no HTTP/2 — the dio (http2 adapter) row is a separate first-party package
package:http             unsupported: dart:io HttpClient speaks HTTP/1.1 only

== HTTP/3 ==
client                    proto  cold_ms   p50_ms   p95_ms   min_ms   max_ms        n    bytes
vane (ffi, h3)           HTTP/3    55.63    24.21    30.33    22.03    35.36       30   125959
vane (dio, h3)           HTTP/3    62.52    25.15    28.59    22.52    29.71       30   125959
rhttp (h3)               HTTP/3   317.52    31.79    37.60    27.23    42.65       30   125959
dio                      unsupported: no HTTP/3 adapter exists for dio
package:http             unsupported: dart:io HttpClient speaks HTTP/1.1 only
```

Warm p50 across the three runs (ms):

| row | run 1 | run 2 | run 3 |
|---|---|---|---|
| vane (ffi, h1) | 24.27 | 25.06 | 24.78 |
| vane (dio, h1) | 23.16 | 24.86 | 30.26 |
| rhttp (h1.1) | 32.76 | 25.36 | 25.02 |
| dio (dart:io) | 32.39 | 24.99 | 34.79 |
| package:http | 31.12 | 25.55 | 27.93 |
| vane (ffi, h2) | 25.67 | 24.03 | 22.30 |
| vane (dio, h2) | 22.96 | 24.37 | 26.15 |
| rhttp (h2) | 26.61 | 25.29 | 31.73 |
| dio (http2 adapter) | 52.69 | 46.15 | 60.22 |
| vane (ffi, h3) | 28.69 | 24.21 | 24.46 |
| vane (dio, h3) | 26.88 | 25.15 | 25.41 |
| rhttp (h3) | 27.66 | 31.79 | 28.08 |

What the numbers say, including where Vane loses:

- **The former 2x HTTP/3 deficit is gone.** Before the vane-rs drive-loop
  fix (`read_quic_packets` slept out its read timeout after every burst),
  vane's warm h3 p50 here was 62–70 ms vs rhttp's 28–30. With the fix it is
  24.2–28.7 ms — ahead of rhttp (h3) in two runs, ~1 ms behind in one:
  parity, with the edge to vane. Same story in the pure-Rust
  `vane-rs/examples/bench.rs`.
- **HTTP/2 is Vane's best column**: fastest row in all three runs
  (22.3–26.2 ms). **dio (http2 adapter) is the stable outlier — last by
  ~2x in every run** (46–60 ms p50, p95 up to 148 ms, chaotic per-round
  drift). No cause is claimed here; as measured, a dio user reaching for
  h2 gets a measurably slower path than any pinned native client in this
  field.
- **HTTP/1.1 is RTT parity, not a ranking**: all five rows sit at
  24–35 ms with overlapping spreads and the strict order shuffles between
  runs. vane (ffi, h1) was fastest-or-tied in all three (24.3–25.1, the
  tightest spread); dio (dart:io) was last in two of three with fat tails
  (p95 63–75 ms in runs 1 and 3). Vane's reqwest-backed TCP path gives
  nothing away to the dart:io clients on this endpoint.
- **Where Vane lost, exactly:** run 3, vane (dio, h1) p50 30.26 ms behind
  rhttp (25.02) and package:http (27.93); run 1, vane (ffi, h3) 28.69 vs
  rhttp (h3) 27.66. Both are single-run wobbles inside the noise band, but
  they are the losses as measured. Vane's h2 rows also each caught one
  ~180 ms max spike in one run (186.10 run 1 ffi, 178.39 run 3 dio) —
  single samples, tracked informally, not visible at p95.
- **The adapter still costs nothing measurable**: vane (ffi) and
  vane (dio) swap places freely within every protocol group.
- **Cold**: vane's cold is 52–77 ms at every protocol — QUIC included —
  vs rhttp (h3)'s 310–318 ms and rhttp (h1.1)'s 96–105 ms (its in-process
  resolver's first lookup is inside those), and dio (http2 adapter)'s
  93–97 ms. Cold numbers are single samples; see caveats.
- HTTP/3 shows no warm-latency win over HTTP/2 or HTTP/1.1 here: to a
  nearby CDN edge over a good network, warm requests are RTT-bound and
  every healthy row clusters at ~22–35 ms. HTTP/3's structural advantages
  (1-RTT/0-RTT setup, no head-of-line blocking, connection migration) are
  about lossy links and connection churn, which this bench does not model.

Ranking stability across the three runs, per group: **HTTP/3** and
**HTTP/2** are stable — same cluster order every run, and the dio (http2
adapter) gap reproduces every run. **HTTP/1.1** has no stable strict
order — it is a parity band; only "vane fastest-or-tied, dio (dart:io)
trailing" repeats.

## Caveats a skeptical reader should raise

- **This is not a vendor benchmark claim.** One machine, one network, one
  endpoint, one payload size, sequential requests, RTT-dominated. It exists
  to catch regressions and place Vane honestly among its peers, not to
  produce a marketing number.
- p50 differences of 1–3 ms between healthy rows are inside this setup's
  noise; the reproducible findings are the ones that survive all three
  runs (the dio h2 adapter gap, the cold-start gaps, the h1 parity band).
- Cold numbers are single samples and not fully symmetric: vane creates its
  native client lazily inside the first request, while rhttp's client is
  created before timing starts; rhttp's cold still includes its in-process
  resolver's first lookup. Treat cold as indicative only.
- The endpoint's body differs by a few bytes between protocols (the page
  echoes the negotiated protocol); payloads are equal in all but name.
- The h2 and h3 rows are prior-knowledge pins on both sides (no ALPN
  downgrade, no Alt-Svc round trip). rhttp's out-of-the-box default
  (`HttpVersionPref.all`) negotiates h2 against this endpoint, so the
  pinned h2 row also stands in for what a default rhttp config gets; the
  earlier separate `rhttp (default)` row was dropped when the matrix made
  it redundant.
- dio_http2_adapter's silent h1.1 fallback is disabled in this harness
  (`onNotSupported` rethrows). A cell that cannot reach its pinned
  protocol reports as an ERROR row — a real result — instead of quietly
  measuring a different protocol.
- `flutter test` runs debug-JIT Dart. The warmup phase absorbs JIT, and
  both Rust cores are release builds, but Dart-side per-request overhead is
  JIT-flavored for every client equally.
- libvane must be built with default features: `--no-default-features`
  drops `tcp-fallback` and the h1/h2 vane rows would fail (loudly — the
  test asserts every vane cell succeeded).

## rhttp integration notes

rhttp ships its Rust core as source and normally builds it via cargokit
inside a Flutter app build. On the host VM the harness instead dlopens a
cargo-built dylib: `tool/build_rhttp.sh` builds the exact rhttp version from
`pubspec.lock` out of the pub cache, with `RUSTFLAGS="--cfg
reqwest_unstable"` — the same flag rhttp's own build tool sets, required by
reqwest's `http3` feature. The harness then calls the generated
`RustLib.init(externalLibrary: …)` directly (an implementation import),
because `Rhttp.init()` only knows the bundled-library loader.
