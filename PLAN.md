# Vane Production Readiness Plan

## Current Status

Vane uses Cloudflare `quiche` for HTTP/3 in the Rust core. The HTTP/2 and
HTTP/1.1 fallback backend, including the previous `reqwest` dependency, has
been removed to reduce binary size.
The public Swift and Kotlin API shape is still intended to stay stable, but the
transport behavior has changed: the default protocol mode is HTTP/3 over QUIC
only. Legacy TCP protocol enum cases remain for source compatibility and fail
with a clear unsupported-transport error.

The repository is now a release-candidate codebase: local release automation
builds and verifies the Rust, Android, and Swift artifacts, and opt-in live
HTTP/3 tests cover request methods, headers, query params, body upload, cookies,
pooling, and certificate pinning. Final production approval still requires
external validation on real iOS/Android devices, clean app archive/import smoke
tests, and benchmark/size validation in release environments.

## Required Feature Coverage

These are the production features Vane should support or explicitly document as
unsupported before release.

| Feature | Current status | Production target |
|---------|----------------|-------------------|
| HTTP/1.0 | Not implemented | Decide whether to support or document as unsupported |
| HTTP/1.1 | Removed from the Rust core | Document as unsupported unless a future fallback backend is reintroduced |
| HTTP/2 | Removed from the Rust core | Document as unsupported unless a future fallback backend is reintroduced |
| HTTP/3 | Implemented with `quiche::h3` | Validate on real mobile devices |
| TLS 1.2 | Not supported by the HTTP/3-only transport | Document as unsupported |
| TLS 1.3 | Provided by quiche | Validate CA loading and failures on all platforms |
| Connection pooling | Implemented as opt-in HTTP/3 idle connection reuse | Validate on real mobile devices |
| Interceptors | Partially implemented as Swift/Kotlin request, response, and error interceptor chains | Add broader platform tests and token-refresh examples |
| Retry | Implemented as opt-in retry policy with backoff and idempotency rules | Add observability hooks if needed |
| Certificate pinning | Implemented with host-scoped SPKI and cert DER pins for HTTP/3 | Validate on real mobile devices |
| Proxy support | Unsupported in the HTTP/3-only build; `proxy_url` fails clearly because QUIC proxying needs MASQUE/CONNECT-UDP | Revisit only with a dedicated HTTP/3 proxy design |
| Custom DNS resolution | Static host-to-IP overrides implemented; dynamic callbacks explicitly unsupported for the first production candidate | Revisit dynamic resolver hooks in a future release |
| Cookies | Implemented as opt-in in-memory cookie jar | Decide persistence strategy in a future release |
| rhttp-style body helpers | Implemented in Swift and Kotlin wrappers for UTF-8 text, JSON, bytes, and URL-encoded form bodies | Add multipart and streaming request bodies in the Rust/FFI layer |
| rhttp-style response helpers | Implemented in Swift and Kotlin wrappers for status validation, bytes, strings/text, and JSON decoding | Add streaming responses, HTTP version, remote IP, and multi-value headers in the Rust/FFI layer |

## rhttp-Inspired Parity Direction

The `rhttp` source is a useful feature checklist, but Vane should keep its own
shape: Rust core, UniFFI bindings, Swift/Kotlin-first ergonomics, and HTTP/3 as
the performance differentiator. Feature parity should therefore mean equivalent
capability, not copying the Dart API.

Already aligned or mostly aligned:
- HTTP/3, TLS 1.3, connection pooling, retry, certificate
  pinning, static DNS overrides, cookies, base URL,
  redirects, user agent, timeouts, request/response interceptors, body limits,
  JSON helpers, and simple response status validation.
- The HTTP/1.1/HTTP/2 fallback backend and `reqwest` dependency were removed;
  Vane's transport path is now the existing `quiche` HTTP/3 implementation.
- Swift and Kotlin wrappers now expose rhttp-like text body, URL-encoded form
  body, response bytes/string/JSON, and throw-on-unexpected-status helpers while
  preserving the existing Vane request builder style.
- The Rust release profile is size-first (`opt-level = "z"`, LTO, single
  codegen unit, stripped symbols, panic abort).

Still intentionally future work:
- Request cancellation tokens wired through Rust execution.
- Upload and download progress callbacks.
- Streaming request and response bodies across UniFFI.
- Multipart form bodies with file/byte/text parts.
- Response metadata for protocol version, remote IP, and multi-value headers.
- TLS settings for min/max TLS version, SNI override, custom root certificate
  sources, and mutual TLS client certificates.
- Dynamic DNS resolver callbacks.
- Dart `http`/Dio compatibility layers, which are not directly applicable to
  Vane unless a Dart/Flutter package is added later.

## Production Gates

### 1. Define protocol and backend strategy

Goal: keep Vane as an HTTP/3-only client unless there is a deliberate future
decision to reintroduce a fallback backend.

Tasks:
- HTTP/1.1 and HTTP/2 fallback code is removed from the Rust core.
- The default protocol mode is `Http3Only`.
- Protocol selection is exposed through `VaneProtocolMode`: HTTP/3-only plus
  legacy fallback/TCP cases. Non-HTTP/3 modes remain only for source
  compatibility and return a clear unsupported error.
- TLS 1.2 is not supported by the HTTP/3-only transport.
- Keep HTTP/3 support on quiche unless another backend is selected.
- HTTP/1.0 remains unsupported.
- Certificate pinning is limited to the HTTP/3 backend.

Acceptance criteria:
- README states that Vane supports HTTP/3 only.
- Tests cover protocol defaults, forced HTTP/3-only behavior, and unsupported
  TCP protocol modes.
- Unsupported protocols fail with a clear typed error.

### 2. Prove HTTP/3 behavior against real servers

Goal: confirm that Vane performs correct HTTP/3 requests end-to-end, not only
that the library compiles.

Tasks:
- Add integration tests that run only when `VANE_TEST_BASE_URL` is set.
- GET, POST, PUT, PATCH, DELETE, headers, query params, body upload, and
  response body assertions are covered by opt-in Rust live tests against an
  HTTP/3-enabled HTTPS endpoint.
- Add negative tests for DNS failure, timeout, TLS verification failure, and
  non-HTTP/3 endpoints when HTTP/3-only mode is selected.
- Confirm response status, headers, final URL, and body match the server output.

Acceptance criteria:
- `cargo test --release` covers unit-level request construction and error paths.
- Swift integration tests pass against a known HTTP/3 endpoint when
  `VANE_TEST_BASE_URL` is set.
- Kotlin Android instrumented tests are env/argument-gated for a known HTTP/3
  endpoint.
- The client fails clearly when the target does not support HTTPS/HTTP/3.

### 3. Harden TLS and certificate verification

Goal: make certificate verification production-safe on macOS, iOS, Android, and
Linux.

Tasks:
- Replace ad hoc platform CA path probing with a deliberate trust strategy.
- Host-scoped certificate pinning is implemented through `VaneClientConfig` and
  Swift/Kotlin builders.
- Supported pin formats are `sha256/<base64-spki-sha256>` and
  `sha256-cert/<base64-cert-der-sha256>`.
- Pin mismatch and missing peer certificates fail closed. Configure at least two
  pins per host to support rotation.
- Verify Android device CA loading works on real devices and emulators.
- Verify iOS device and simulator CA loading works, or bundle a trusted root
  store if platform roots cannot be consumed reliably by quiche.
- Add tests for valid certificates, expired certificates, hostname mismatch,
  self-signed certificates, missing CA roots, valid pins, backup pins, and pin
  mismatch.
- Add an explicit insecure mode only for tests, if needed, and ensure it cannot
  be enabled accidentally in release builds.

Acceptance criteria:
- TLS verification is enabled by default on every platform.
- Certificate pinning is opt-in, host-scoped, and fails closed on mismatch.
- Pin rotation is possible by configuring at least two pins per host.
- Pinning is validated by opt-in Rust live tests when `VANE_TEST_CERT_PIN` is
  set, and still needs iOS/Android device validation.
- Real iOS and Android devices can call a public HTTP/3 API without custom setup.
- Invalid certificates produce a typed `VaneError` with a useful message.

### 4. Stabilize quiche request lifecycle

Goal: make the blocking quiche transport robust enough for mobile SDK use.

Tasks:
- Review connection timeout, read timeout, idle timeout, and retry behavior.
- Configurable request and response body limits are implemented through
  `max_request_body_bytes` and `max_response_body_bytes`.
- Handle partial writes, large request bodies, and streaming response chunks.
- Confirm QUIC packet flushing is correct after request send, response receive,
  and close.
- Decide whether connection reuse/pooling is required for production performance.
- Add structured error mapping for DNS, socket, QUIC, HTTP/3, TLS, timeout, and
  response-body limit failures.

Acceptance criteria:
- No busy-loop behavior under packet loss, timeout, or closed connections.
- Large bodies fail or stream predictably according to documented limits.
- Errors returned through Swift/Kotlin are stable enough for app developers to
  handle.

### 5. Add connection pooling and request policies

Goal: support production traffic without opening a new connection for every
request.

Tasks:
- HTTP/3 connection pooling is implemented behind
  `connection_pool_enabled`. It is keyed by scheme, host, port, protocol mode,
  static DNS override, and certificate pins.
- Idle connection expiry and max idle connection limits are implemented through
  `connection_idle_timeout_seconds` and `max_idle_connections`.
- Optional retry policy is implemented through `retry_max_attempts`,
  `retry_initial_delay_millis`, `retry_max_delay_millis`, and
  `retry_unsafe_methods`.
- Retry only safe/idempotent requests by default, and retrying POST/PATCH is
  opt-in through `retry_unsafe_methods`.
- Add jitter if production traffic needs it; current backoff is deterministic
  for predictable tests.
- Define retry behavior for DNS, socket, QUIC, TLS, HTTP/3, timeout, reset, and
  server status errors.
- Add observability hooks for request attempts, retries, connection reuse, and
  failures.

Acceptance criteria:
- Multiple requests to the same host reuse a connection when allowed.
- Retry behavior is disabled by default and configured explicitly.
- Retry tests prove no accidental duplicate unsafe requests.
- Opt-in live HTTP/3 integration tests prove pooled connections work with real
  servers.

### 6. Add interceptors

Goal: support app-level request/response behavior without forcing callers to
wrap every request manually.

Tasks:
- Swift and Kotlin request, response, and error interceptor APIs are
  implemented on `VaneSession`.
- Async interceptors are supported, so platform APIs can inject auth headers,
  refresh tokens, inspect responses, and map errors.
- Ordering is request interceptors in registration order, Rust execution,
  response interceptors in registration order. Error interceptors may return a
  synthetic response; returned responses still pass through response
  interceptors.
- Ensure sensitive values are not logged by default.

Acceptance criteria:
- Apps can implement auth header injection and token refresh via interceptors.
- Interceptors are applied consistently across direct methods and request
  builder paths.
- Interceptor failures propagate as platform errors and can be mapped through
  error interceptors.

### 7. Proxy support

Goal: document proxy support as unavailable in the HTTP/3-only build unless a
future MASQUE/CONNECT-UDP transport is added.

Tasks:
- `proxy_url` and `proxy_authorization` remain in `VaneClientConfig` and the
  Swift/Kotlin builders for source compatibility.
- Any request with `proxy_url` configured fails clearly in the HTTP/3 backend.
- HTTP/3 proxying remains unsupported until a MASQUE/CONNECT-UDP
  implementation is added.

Acceptance criteria:
- README documents that proxies are unsupported in this build.
- Unit tests cover HTTP/3 proxy rejection.

### 8. Add custom DNS resolution

Goal: let apps control name resolution for split-horizon DNS, testing, private
networks, and advanced routing.

Tasks:
- Add a resolver abstraction in Rust that can resolve host and port to one or
  more socket addresses.
- Expose static host overrides through `VaneClientConfig`.
- Static host-to-IP overrides are implemented. Dynamic resolver callbacks
  through UniFFI are explicitly unsupported for the first production candidate.
- Preserve the original hostname for SNI, Host/authority, and certificate
  verification.
- Add tests for IPv4, IPv6, multiple addresses, failed resolution, and host
  override behavior.

Acceptance criteria:
- Custom DNS can route a host to a chosen IP without breaking TLS hostname
  verification.
- Static resolver errors are typed and visible to Swift/Kotlin.
- Fallback address ordering is deterministic or documented.

### 9. Add cookies

Goal: support session-oriented APIs without making cookies mandatory for all
clients.

Tasks:
- Optional in-memory cookie jar is implemented behind `cookies_enabled`.
- `Set-Cookie` parsing, `Cookie` header generation, `Max-Age`
  expiration/deletion, domain scoping, path scoping, and Secure cookie scoping
  are implemented.
- HttpOnly and SameSite are accepted as attributes, but they do not change SDK
  behavior yet because Vane is not a browser runtime.
- Cookie enable/disable behavior is exposed in Swift and Kotlin configuration
  builders.
- Platform persistence is deferred to a future release.

Acceptance criteria:
- Cookie behavior matches standard browser/client expectations for common SDK
  cases.
- Cookies are disabled and isolated per client/session by default.
- Cookie tests cover domain/path/security scoping.

### 10. Fix packaging for Swift production use

Goal: ship a Swift package that is small, usable, and acceptable for target
distribution channels.

Tasks:
- The Swift artifact is now built as a static XCFramework through
  `cargo swift package --lib-type static`.
- `vane-rs` enables both `cdylib` for Android/UniFFI bindgen and `staticlib`
  for Swift/iOS packaging.
- The App Store risk from shipping a dynamic cargo-swift XCFramework is closed
  for the generated package. Keep optimizing size through release profile,
  dependency features, and app-linker behavior.
- A size-optimized Swift static profile is available through
  `make build_swift_small`; it outputs `RustFramework.small.xcframework` and
  disables SPKI pin parsing. Use it only for apps that can use
  `sha256-cert/<base64>` pins.
- Confirm `RustFramework.xcframework` loads in a clean iOS app and a clean macOS
  app.
- SwiftPM live tests pass without `VANE_TEST_BASE_URL`. Live HTTP/3 validation
  requires a confirmed HTTP/3 endpoint; `https://httpbin.org` fails the QUIC
  handshake in the current verification environment.
- Add an example iOS app smoke test, or run a clean app smoke test in the
  release environment.
- Ensure `Package.swift` and the generated xcframework agree on platform and
  deployment targets.

Acceptance criteria:
- A clean iOS app can import `VaneSwift`, build, launch, and perform an HTTP/3
  request.
- The selected library type is documented with a clear reason: static
  XCFramework is preferred for App Store distribution safety.
- Swift release artifact size is measured and recorded per slice.

### 11. Fix packaging for Android production use

Goal: ship an Android AAR that is small, ABI-correct, and release-safe.

Tasks:
- Confirm all required `libvane.so` and `libquiche-*.so` files are included in
  the release AAR.
- Confirm ABI filters match the intended release targets.
- Android instrumented smoke tests are gated by the `VANE_TEST_BASE_URL`
  instrumentation argument and use HTTPS/HTTP3 endpoints instead of a hardcoded
  LAN server.
- Consumer R8/ProGuard keep rules are present for Vane, JNA, and native methods.
- Remove accidental files from native output, such as `.DS_Store`, if present.
- Emulator ABIs are currently built and published for test coverage. Decide
  whether to exclude emulator-only ABIs for a smaller production artifact.

Acceptance criteria:
- A clean Android app can import the AAR, launch, and perform an HTTP/3 request.
- Release APK/AAR size is measured and recorded.
- Native library loading works on at least one physical Android device.

### 12. Add CI and release automation

Goal: make every release reproducible.

Tasks:
- CI workflow is implemented at `.github/workflows/release.yml` for Rust
  format, clippy, tests, Android release AAR build, Kotlin unit tests, Swift
  package build, and Swift tests.
- CI reports artifact sizes for Android native libs, Android release AAR, and
  Swift xcframework slices through `scripts/report-artifact-sizes.sh`.
- Release script is implemented at `scripts/release-build.sh`. It regenerates
  Kotlin and Swift UniFFI bindings, rebuilds native artifacts, runs Rust checks,
  Android release build, Kotlin unit tests, Swift tests, and rejects accidental
  `.DS_Store` files in Android native output.
- CI fails if generated bindings or native artifacts are stale after running
  the release script.

Acceptance criteria:
- A clean checkout can build all release artifacts without manual prompts.
- CI reports binary sizes on every release candidate.
- Release commands are documented and deterministic.

### 13. Update documentation and examples

Goal: keep transport documentation aligned with the current HTTP/3-only quiche
backend strategy.

Tasks:
- Update README references to the current `quiche` HTTP/3-only backend.
- Document that Vane currently targets HTTP/3 over HTTPS.
- Add setup docs for `VANE_TEST_BASE_URL`.
- Add Swift and Kotlin examples that use real HTTPS URLs.
- Document timeout, TLS, error behavior, response body limits, and unsupported
  protocols.
- Remove or revise old benchmark claims until they are re-measured with quiche.

Acceptance criteria:
- README accurately describes the current backend and protocol behavior.
- Examples compile and match the generated Swift/Kotlin APIs.
- Benchmark numbers are either current or clearly marked as pending.

### 14. Re-benchmark and size-optimize

Goal: prove the migration actually improves size/performance under realistic
conditions.

Tasks:
- Benchmark Vane over HTTP/3 against URLSession, Alamofire, OkHttp, and Retrofit
  where comparisons are meaningful.
- Measure cold start, first request latency, repeated request latency, memory,
  and binary size.
- Compare static vs dynamic Swift artifacts.
- Review Cargo release profile settings: LTO, codegen-units, panic strategy,
  strip, and symbol visibility.
- Review quiche feature flags and remove unused features if possible.

Acceptance criteria:
- Benchmark methodology is documented.
- Size and performance numbers are reproducible.
- Any size tradeoff from quiche, BoringSSL, or dynamic packaging is explicit.

### 15. Security and abuse-resistance review

Goal: avoid shipping an HTTP client that can be misused or fail unsafely.

Tasks:
- Review SSRF-relevant behavior if apps can pass untrusted URLs.
- Confirm redirects are either unsupported or safely implemented.
- Configurable request and response body limits are implemented through
  `max_request_body_bytes` and `max_response_body_bytes`.
- Add timeout defaults that cannot hang app threads indefinitely.
- Ensure certificate pinning cannot be bypassed by redirects, alternate hosts,
  or fallback transport behavior.
- Ensure sensitive headers are not logged in examples or errors.
- Review dependency licenses and supply-chain posture for quiche/BoringSSL.

Acceptance criteria:
- Security-sensitive defaults are documented.
- Unsafe options are opt-in and clearly named.
- Dependency licenses are acceptable for commercial distribution.

## Suggested Order

1. Protocol/backend strategy.
2. HTTP/3 integration tests.
3. TLS verification and certificate pinning on real iOS and Android devices.
4. Connection pooling and retry policy integration tests.
5. Proxy and custom DNS support.
6. Cookies.
7. Swift and Android clean-app smoke tests.
8. CI and release automation.
9. README and examples update.
10. Benchmarks and final size optimization.
11. Security review.

## Release Candidate Checklist

- [x] `cargo fmt`
- [x] `cargo clippy --release --all-targets`
- [x] `cargo test --release`
- [x] `make build_kotlin`
- [x] Android release AAR builds locally
- [ ] Android release AAR builds from a clean checkout in CI
- [ ] Android clean app loads the AAR and performs an HTTP/3 request on a real device
- [x] `make build_swift`
- [x] `swift test`
- [x] Swift XCFramework is static and contains `libvane.a` slices
- [ ] Swift live HTTP/3-only GET passes against a confirmed HTTP/3 endpoint
- [ ] Swift clean app imports the package and performs an HTTP/3 request
- [x] Protocol matrix defaults and forced HTTP/3-only behavior are unit-tested
- [x] Connection pooling unit tests pass
- [x] Retry policy tests pass
- [x] Connection pooling integration tests are implemented and env-gated
- [x] Swift interceptor tests pass
- [x] Kotlin interceptor tests pass
- [x] Proxy unit tests pass for unsupported HTTP/3 proxy mode
- [x] Static custom DNS tests pass
- [x] Dynamic custom DNS resolver support is implemented or documented as unsupported
- [x] Cookie tests pass
- [x] Request and response body limits are implemented and tested
- [x] Artifact sizes are recorded
- [x] README and examples match HTTP/3-only behavior
- [ ] TLS tests pass on real devices
- [x] Certificate pinning unit tests pass for valid cert pins, backup pins, mismatch, and missing peer cert
- [x] Certificate pinning integration test is implemented and env-gated for a confirmed HTTP/3 endpoint
- [x] No generated or temporary files are left outside intended artifact paths
- [x] `graphify update .` has been run after code changes

## Known Current Risks

- Forced HTTP/3-only Rust and Swift tests fail against `https://httpbin.org`
  with `QUIC connection closed before handshake completed`. A confirmed HTTP/3
  test endpoint is still required for final live validation.
- TLS root loading still needs real-device validation across the quiche path.
- Certificate pinning has unit coverage and an env-gated live HTTP/3 test, but
  still needs real-device validation.
- HTTP/1.0 is not implemented.
- HTTP/1.1 and HTTP/2 fallback were removed from the Rust core.
- Certificate pinning is enforced for HTTP/3 only.
- Connection pooling and retry have unit coverage. Connection pooling has
  env-gated live HTTP/3 coverage; retry still needs purpose-built failure
  integration coverage if observability hooks are added.
- Interceptors are implemented and covered by Swift and Kotlin wrapper tests.
- Cookies are implemented as an opt-in in-memory jar with env-gated live HTTP/3
  coverage. Persistence is deferred to a future release.
- Proxy support is unavailable in the HTTP/3-only build until
  MASQUE/CONNECT-UDP is implemented.
- Dynamic custom DNS callbacks are explicitly unsupported in this release
  candidate.
- Swift XCFramework packaging is static now, but clean iOS app import/build and
  App Store archive validation still need to be run.
- SwiftPM on macOS still emits linker warnings that BoringSSL objects inside
  `libvane.a` were built for macOS 26.1 while linking for macOS 14.0. This needs
  a packaging/toolchain fix before release.
- Static Swift archives are larger than the old dynamic `.dylib` slices; measure
  final linked app and IPA size before making production size claims.
- Existing benchmark claims were written for the old backend and must be
  re-measured.
- `http://` URLs are rejected because QUIC/TLS requires `https://`.
