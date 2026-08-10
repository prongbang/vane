# vane_benchmark_ios

Client × protocol HTTP latency matrix on Apple platforms: **vane**
(`VaneSwift`, the Rust core via UniFFI) pinned to HTTP/1.1, HTTP/2 and
HTTP/3; **URLSession** (the platform baseline); **Alamofire** (the de-facto
wrapper, which sits on URLSession) — one process on the **iOS Simulator**,
one endpoint, sequential GETs, grouped per protocol so every comparison is
like-for-like.

Repo-internal tooling, and a **separate package on purpose**: Alamofire must
never appear in `VaneSwift/Package.swift` — the manifest every consumer
resolves — mirroring how `vane_benchmark/` keeps rhttp/dio out of the
shipping Dart packages. This package depends on `VaneSwift` by path and pulls
Alamofire only for itself.

## Run it

```sh
make bench            # iPhone 17 Pro / iOS 26.1 / cloudflare-quic.com
```

which is:

```sh
env TEST_RUNNER_VANE_TEST_BASE_URL=https://cloudflare-quic.com \
    TEST_RUNNER_VANE_BENCH_JSON=$PWD/results/latest.json \
    xcodebuild test \
    -scheme vane_benchmark_ios-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1'
```

`TEST_RUNNER_`-prefixed variables must be in xcodebuild's **environment**
(passing them as `KEY=value` command-line build settings silently does
nothing); Xcode strips the prefix and injects them into the test process,
where the harness reads `VANE_TEST_BASE_URL` etc. Without a base URL the test
prints a skip message and passes, like every live-gated test in this repo.
Knobs: `VANE_BENCH_ROUNDS` (3), `VANE_BENCH_REQUESTS` per round (10),
`VANE_BENCH_WARMUP` (5). The simulator test process writes the JSON metrics
file directly to the host path in `VANE_BENCH_JSON` (simulator tests share
the host filesystem), and the same JSON is always printed to the log between
`VANE_BENCH_JSON_BEGIN`/`END` markers as a fallback. `results/latest.json`
is gitignored scratch; runs worth keeping are copied to
`results/<date>-<label>.json` by hand.

`make bench_macos` runs the identical harness on the host via `swift test` —
a diagnostic convenience, **not** the deliverable.

## The matrix, and who can actually pin

| client | HTTP/1.1 | HTTP/2 | HTTP/3 |
|---|---|---|---|
| vane | `http1Only` | `http2Only` | `http3Only` |
| URLSession | — no API can pin it | ALPN-negotiated | `assumesHTTP3Capable` hint |
| Alamofire | — same, sits on URLSession | ALPN-negotiated | `assumesHTTP3Capable` hint |

Only Vane can pin. URLSession exposes no HTTP-version knob below
`URLRequest.assumesHTTP3Capable`, which is a **hint** — it races QUIC and
silently falls back to TCP — not a pin; and nothing can forbid h2, so the
URLSession/Alamofire HTTP/1.1 cells are printed as `unsupported`. Every
row's proto column is **observed**, never assumed: Vane reports
`VaneResponse.httpVersion`, URLSession/Alamofire report
`URLSessionTaskMetrics.transactionMetrics.networkProtocolName`. A row whose
observed protocol differs from its group prints a NOTE — on macOS hosts the
`(alpn)` rows really do get silently upgraded to h3 by Foundation's Alt-Svc
cache and the NOTE fires; across the recorded simulator runs they stayed h2.

## What it measures

Methodology mirrors `vane_benchmark/test/benchmark_test.dart`: per client
one **cold** request on a fresh client (reported alone), then 5 discarded
warmups, then 3 rounds × 10 measured sequential GETs of `<base>/`, visiting
order rotated each round; `p50`/`p95` are nearest-rank over the pooled
samples (the `vane-rs/examples/bench.rs` formula); DNS resolved once before
any client runs; status checked identically everywhere; per-client failures
become ERROR rows without killing the run. Pooling/keep-alive ON for every
client (each one's default). Response caching OFF for URLSession/Alamofire
(ephemeral config, no URLCache) because Vane has no response cache — a cache
would benchmark the cache. The per-request guard is each client's 30 s
request timeout (Vane's shipped default, mirrored onto the URLSession
configs).

## Results — iOS Simulator, 2026-08-11 (post-drive-loop-fix XCFramework)

**Simulator numbers use the Mac host's network stack and scheduler. They are
NOT iPhone-hardware numbers.** iPhone 17 Pro simulator, iOS 26.1, Xcode
26.1.1, macOS host, `https://cloudflare-quic.com` (~126 KB body), 30 samples
per row per run, three full runs (`results/2026-08-11-sim-run{1,2,3}.json`).

Provenance: an earlier 2026-08-11 measurement used a **stale XCFramework**
(archives committed 20:51 the previous evening; the vane-rs drive-loop fix
landed 23:09) and showed `vane (h3)` at a stable 75-77 ms p50 — that number
measured the pre-fix drive loop, which slept out its read timeout after
every burst, not the current core. The tables below are from the rebuilt
archives (`make build_swift` at HEAD); the harness is byte-identical between
the two number sets, so the artifact's age was the only variable.

p50 ms per run (p95 range across runs in brackets):

| group | client | run1 | run2 | run3 | p95 range |
|---|---|---|---|---|---|
| HTTP/1.1 | vane (h1) | **30.8** | **28.2** | **29.0** | 72-246 |
| HTTP/1.1 | urlsession | unsupported | | | |
| HTTP/1.1 | alamofire | unsupported | | | |
| HTTP/2 | vane (h2) | 29.1 | **22.8** | 28.0 | 50-104 |
| HTTP/2 | urlsession (alpn) | 29.0 | 23.8 | 25.1 | 30-45 |
| HTTP/2 | alamofire (alpn) | **26.9** | 28.0 | **23.4** | 33-80 |
| HTTP/3 | vane (h3) | **26.4** | 30.4 | 33.5 | 37-180 |
| HTTP/3 | urlsession (h3 hint) | 29.3 | **23.5** | **25.1** | 27-42 |
| HTTP/3 | alamofire (h3 hint) | 30.1 | 29.5 | 31.0 | 34-40 |

Ranking stability over the three runs:

- **HTTP/3: parity at the median, no stable winner.** `vane (h3)` wins run
  1 (26.4 ms) and trails URLSession by 3-8 ms in runs 2-3 — inside network
  noise, order unstable. The pre-fix 2.5-3× deficit is gone.
- **HTTP/2: a three-way tie inside network noise.** All clients in the
  23-29 ms band; the order flips every run. The protocol column matters
  more than the client here.
- **HTTP/1.1: only Vane can play**, so it wins the group by default, with a
  steady ~28-31 ms p50.
- **Where Vane still loses: the tail.** Vane's p95 is the fattest of its
  group in most runs (h1 up to 246 ms, h2 up to 104 ms, h3 up to 180 ms,
  against URLSession's 27-45 ms band). Median parity, weaker tail — as
  measured, unexplained here.
- Alamofire vs URLSession: statistically inseparable — the wrapper's cost
  over its own engine does not rise above network noise at this RTT, and
  their order flips run to run.
- Cold requests are noisy everywhere; Vane's colds (up to ~795 ms on the
  first row of a run) additionally pay one-time FFI/runtime initialization
  for the whole process, which lands in whichever Vane row runs first.

Other caveats: one machine, one network, sequential requests — this is
RTT-dominated, not a lab; Foundation's Alt-Svc upgrades are environmental
state the harness reports but cannot fully isolate (on macOS hosts the
`(alpn)` rows really do get upgraded to h3 and the NOTE fires; on the
simulator they stayed h2 in every recorded run); and the h3-hint rows
measure "URLSession allowed to race QUIC", not a pinned h3 — their observed
protocol just happened to be h3 in every recorded run.
