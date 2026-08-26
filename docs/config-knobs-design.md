# Vane item-4 config knobs — API design (rev 2, post-adversarial-review)

Design only; no code edits. Anchors are file:line in the current tree (recon-verified plus spot checks this session, plus two adversarial verify passes whose fixes are folded in below). Baseline facts this design leans on, spot-checked today:

- Vane is **https-only for request URLs** — enforced at `vane-rs/src/lib.rs:1756`, `tcp.rs:789`, `tcp.rs:1204`. This kills rhttp's per-scheme proxy union (see 1e).
- `QuicConfigCache`, `TlsSessionStore`, and the H3 pool are **per-`VaneClient` fields** (`lib.rs:1041-1053`), not process globals. Config is immutable per client, so new knobs need no cache-key changes there; only `PoolKey` gets additions, for convention-consistency with `proxy_url` (also immutable, already keyed). Note: `create_quiche_config` (`lib.rs:4345`) re-runs on every `QuicConfigCache` **miss** (`lib.rs:3477`) — anything it needs must live on the client for the client's lifetime, not be consumed once.
- `rustls-platform-verifier` 0.7.0 has `Verifier::new_with_extra_roots` on apple/windows/others (`verification/apple.rs:73`, `windows.rs:569`, `others.rs:35`) but **NOT on Android** — `verification/android.rs:66-76` exposes only `Verifier::new(provider)` plus a test-gated fake-root hook. A per-platform extra-roots call is therefore either an Android build break or a silent Android no-op. **Consequence: custom roots on TCP use a vane-side OR-composite verifier, uniform on all platforms** (3c).
- `rustls-pki-types` 1.15.1 is in-tree with PEM parsing (`pem.rs`, `PemObject::from_pem_slice` / `pem_slice_iter`). No new dependency for PEM on the TCP path.
- quiche 0.29.1 ships `Config::with_boring_ssl_ctx_builder(version, boring::ssl::SslContextBuilder)` (`quiche-0.29.1/src/lib.rs:644`) under the **default** feature `boringssl-boring-crate`; the single `boring` 4.22.0 in Cargo.lock is already linked for `spki-pinning`. `tls::Context::from_boring` calls `set_session_callback()` and skips only `load_ca_certs()` relative to `Context::new()` (`tls/mod.rs:136-160`) — the one delta the builder path must cover (vane's `load_platform_roots` already supersedes it). `Handshake::init` pins TLS min=max=1.3 per connection (`tls/mod.rs:381-382`), independent of how the context was built. **Consequence: all H3 TLS material (custom roots, client cert, key) loads from memory via the ctx builder — no temp files anywhere** (3c/3d).
- Protocol modes (`lib.rs:795-806`): `Http3ThenHttp2ThenHttp1`(0), `Http3Only`(1), `Http2ThenHttp1`(2), `Http2Only`(3), `Http1Only`(4). "H3-capable" below means modes 0-1.

## 0. Decisions at a glance

| Knob | Surface | Default | Verdict vs rhttp |
|---|---|---|---|
| a. maxRedirects | `max_redirects: u32` config field | 10 (today's const) | parity; upper clamp 64 added (security bound stays bounded) |
| b. TLS versions | `tls_min_version`/`tls_max_version: Option<VaneTlsVersion>` | None/None (= 1.2+1.3 on TCP) | parity on TCP; **H3 validates only** — QUIC is TLS 1.3-always (RFC 9001, quiche hardcodes it) |
| c. Custom roots | `custom_root_certificates: Vec<String>` (PEM) | `[]` | **extend-only**; no replace mode, no verification-off switch — both rejected deliberately; extend via OR-composite verifier on TCP (Android-proof), in-memory boring store on H3 |
| d. mTLS | `client_certificate: Option<VaneClientCertificate>` (PEM chain + PEM key) | None | parity; one input format both stacks consume, fully in-memory, redacting `Debug` |
| e. Proxies | `proxy_url` + `proxy_authorization` stay THE surface | unset = no proxy | **rhttp union not ported** — provably meaningless in an https-only client (proof in 1e) |
| f. DNS resolver | `set_dns_resolver()` method on the client, NOT a config field | unset = overrides→system | sync UniFFI foreign trait (Swift/Kotlin); request-id rendezvous over C ABI (Dart); `dns_overrides` wins over the resolver; setter drains BOTH transports' cached state |
| g. remoteIp | `VaneResponse.remote_ip: Option<String>` | — | parity-plus: populated on H3 too (rhttp/reqwest can't) |
| h. List headers | `VaneResponse.headers` becomes `Vec<VaneHeader>` (ordered, duplicates kept); `set_cookie` field **dropped**; map + multimap views become derived getters | — | breaking change taken (packages unpublished); fixes the lossy `", "` join; Dart ships all three rhttp views (headers/headerMap/headerMapList) |

One ABI bump: **v4 → v5, once, in batch 1**, covering every struct field, one changed symbol signature (`vane_ffi_client_create` gains `out_error_kind`, §4c), and every new symbol for all four batches (section 4).

---

## 1. FIELDS

New `VaneClientConfig` fields, **appended after `proxy_authorization` in this order**, every one carrying `#[uniffi(default = ...)]` so the four hand-built Kotlin JVM config literals keep compiling (recon §7b):

```rust
// vane-rs/src/lib.rs — VaneClientConfig (append after proxy_authorization)
#[uniffi(default = 10)]
pub max_redirects: u32,
#[uniffi(default = None)]
pub tls_min_version: Option<VaneTlsVersion>,
#[uniffi(default = None)]
pub tls_max_version: Option<VaneTlsVersion>,
#[uniffi(default = [])]
pub custom_root_certificates: Vec<String>,
#[uniffi(default = None)]
pub client_certificate: Option<VaneClientCertificate>,
```

New supporting types:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum VaneTlsVersion { Tls12, Tls13 }

// NO derive(Debug) — VaneClientConfig derives Debug (lib.rs:807), and a derived
// Debug here would print the private key on any `{:?}` of a config. Manual impl.
#[derive(Clone, uniffi::Record)]
pub struct VaneClientCertificate {
    /// PEM, leaf first, optionally followed by intermediates (full chain).
    pub certificate_pem: String,
    /// PEM PKCS#8, SEC1, or PKCS#1 private key. Never logged, never echoed in
    /// errors, never printed by Debug.
    pub private_key_pem: String,
}

/// Redacting Debug: never prints PEM material. The cert side may show a
/// SHA-256 fingerprint (public data); the key side is always "<redacted>".
impl std::fmt::Debug for VaneClientCertificate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VaneClientCertificate")
            .field("certificate_pem", &format_args!("<sha256:{}>", self.certificate_fingerprint()))
            .field("private_key_pem", &"<redacted>")
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VaneHeader { pub name: String, pub value: String }   // used by (h)
```

A batch-3 test asserts `format!("{:?}", config)` with a populated `client_certificate` contains no PEM material (no `-----BEGIN`, no key bytes). Same treatment applies if `VaneClientConfig` ever gains `Display`.

`impl Default for VaneClientConfig` (`lib.rs:832`) gains the same five values: `10, None, None, vec![], None`. **Rule for every layer**: the default is spelled identically in Rust `Default`, the Dart `VaneConfiguration` ctor, and the Dart `_NativeConfig` `??` fallback — do not repeat the existing 4-vs-8 / 25-vs-30 divergence (recon §1h). The plugin `configFromMap` paths inherit defaults from `createDefaultConfig()` automatically.

All validation happens once, in `VaneClient::new` (`lib.rs:1055`), as `VaneError::InvalidRequest`, matching the proxy-scheme precedent. No PEM or key material ever appears in an error message (same discipline as `redact_url_userinfo`, `lib.rs:4523`). Swift/Kotlin see the typed `VaneError.InvalidRequest`; Dart gets the same kind via the v5 `out_error_kind` out-param on `vane_ffi_client_create` (§4c) — no binding is left with `kind: unknown` on a validation failure.

### (a) `max_redirects: u32` — default 10

- Replaces the `MAX_REDIRECTS` const (`lib.rs:78-80`) as the hop cap; `follow_redirects: bool` stays the on/off switch, config- and per-request, unchanged.
- Semantics: `follow_redirects=false` → the 3xx is returned as a normal response (today's behavior). `follow_redirects=true` and the chain exceeds `max_redirects` → `Refused(REDIRECT_REFUSED_HOP_CAP)` exactly as today. `max_redirects=0` with follow on → the *first* 3xx is a hop-cap refusal (matches reqwest `Policy::limited(0)`).
- Validation: `max_redirects > 64` → `InvalidRequest("maxRedirects must be at most 64: the redirect hop cap is a security bound")`. The const's comment survives as the error message. Being `u32`, rhttp's negative-cap wraparound defect is unrepresentable.
- Config-level only. No per-request override (per-request `follow_redirects` already exists; a per-request cap is speculative — add if a real caller asks).

### (b) `tls_min_version` / `tls_max_version: Option<VaneTlsVersion>` — default None/None

- `None`/`None` = today's behavior: rustls `DEFAULT_VERSIONS` (TLS 1.2 + 1.3) on TCP, TLS 1.3 on H3.
- **Enforced on the TCP path only.** QUIC is TLS 1.3-always: quiche 0.29.1 hardcodes `set_min_proto_version(TLS1_3_VERSION)` / `set_max_proto_version(TLS1_3_VERSION)` inside `Handshake::init` (`tls/mod.rs:381-382`); no quiche API changes it and RFC 9001 mandates it. **On H3 the knob validates compatibility and does nothing else.**
- Validation, in order:
  1. `min > max` → `InvalidRequest("tlsMinVersion must not exceed tlsMaxVersion")`.
  2. `tls_max_version == Some(Tls12)` **and** `protocol_mode` is H3-capable (`Http3ThenHttp2ThenHttp1` or `Http3Only`) → `InvalidRequest("tlsMaxVersion tls12 is incompatible with HTTP/3: QUIC mandates TLS 1.3 (RFC 9001); use an HTTP/2/1 protocolMode or raise tlsMaxVersion")`. Loud at construction, never a silent per-transport divergence.
  3. `tls_min_version == Some(Tls13)` is valid everywhere (TCP enforces 1.3-only; H3 already is 1.3).
- Both values enter `PoolKey` (`lib.rs:2601`) per the plumbing rule: connection-identity config is keyed, same as `proxy_url`.

### (c) `custom_root_certificates: Vec<String>` — default `[]`

- Each entry is a PEM string holding **one or more** certificates (a caller may pass one bundle string or a list of singles; the core concatenates — PEM is concatenation-safe, which is also how it rides the C ABI as a single buffer, §4).
- **Combine semantics: EXTEND, always.** Custom roots are *added to* platform trust on both stacks. There is **no replace mode and no verification-off switch**:
  - Replace mode (`RootCertSource::none`/`webpki` in rhttp) is not ported. rhttp's own default (bundled webpki snapshot replacing OS roots) is the defect the recon flagged: a shipped app stops honoring OS root updates/revocations. Vane's platform-trust default is the better posture; a private-PKI-only "replace" enum can be appended later behind the same field if a real deployment demands it — it would be a new enum field, config-parse only, no ABI layout change.
  - `verifyCertificates: false` is **never** ported, per the brief. Vane's hermetic-test need is already served by the compiled-out `h3_offline` / `TEST_ROOT` seams (recon §3d).
- **Mechanism (uniform on ALL platforms — the Android hole is why):** TCP uses a vane-side **OR-composite verifier** — platform `Verifier` OR a `rustls::client::WebPkiServerVerifier` built over the parsed custom roots; a chain is accepted if **either** full verifier accepts it. Sound because each arm performs complete chain+name+validity verification on its own root set — the union of two valid trust decisions is exactly "extend". One code path, one behavior to test, no per-OS `new_with_extra_roots` drift (Android has no such API at all, baseline above). Details in 3c. H3 adds the parsed roots to the boring cert store on the ctx-builder path (3c) — in memory, no files.
- **Pins are unaffected and still win.** `verify_certificate_pins` runs post-handshake on H3 (`lib.rs:2124`, `:3684`) and inside the rustls verifier on TCP (`tcp.rs:84`) regardless of which root anchored the chain — the composite sits **beneath** `PinnedServerCertVerifier`, so pins are enforced above whichever arm accepted. A custom root can never widen a pinned host's acceptance. The pins⇒no-resumption rule (`may_resume_tls_session`, `lib.rs:3510`) is untouched.
- Validation: every entry must parse to ≥1 certificate (`CertificateDer::pem_slice_iter` on the TCP side, `boring::x509::X509::stack_from_pem` on the H3 side; both default features). Failure → `InvalidRequest("customRootCertificates[{i}] is not valid PEM certificate data")` — index only, never content.
- A SHA-256 fingerprint of the concatenated PEM enters `PoolKey` (convention; caches are per-client so this is defensive, not load-bearing today).

### (d) `client_certificate: Option<VaneClientCertificate>` — default None

- **One input format for both stacks: PEM chain + PEM key** (`VaneClientCertificate` above). Chosen because it is the only format both consumers accept without conversion code:
  - rustls: `CertificateDer::pem_slice_iter` + `PrivateKeyDer::from_pem_slice` (pki-types 1.15, in-tree) → `.with_client_auth_cert(chain, key)` replacing `.with_no_client_auth()` at `tcp.rs:382`.
  - quiche/boring: chain via `X509::stack_from_pem` → `SslContextBuilder::set_certificate` + `add_extra_chain_cert`; key via `PKey::private_key_from_pem` → `set_private_key` — **entirely in memory** on the ctx-builder path, mechanism in 3d. No key bytes ever touch flash (an unlinked temp file does not scrub NAND; the in-memory path is strictly stronger than any 0600+delete scheme).
  - PKCS#12 is deliberately out (rhttp can't reach it either; boring/rustls PEM covers the real use).
- Validation at construction: chain parses to ≥1 cert; key parses to exactly one supported key; a cert/key mismatch surfaces as early as each stack allows (rustls errors at client build; boring at quiche-config build) — always as `InvalidRequest`/`Tls` **without echoing material**. Error text: `"clientCertificate PEM did not parse"` / `"clientCertificate privateKey did not parse"`.
- Key hygiene: the key PEM is held on the client as `Zeroizing<String>` (zeroize is in-tree via pki-types) because `create_quiche_config` re-runs per `QuicConfigCache` miss (baseline) — retained for the client lifetime, wiped on drop, never written to disk, never printed (redacting `Debug`, §1 types).
- SHA-256 fingerprint of `certificate_pem` enters `PoolKey` — a pooled connection authenticated as identity A must never serve a config with identity B (immutable today; keyed anyway, same as proxy_url).
- Session resumption: no change needed. The TLS session store and TCP resumption cache are per-client (`lib.rs:1041-1053`, `tcp.rs:389`), and the client certificate is per-client immutable, so every cached session was established under the same identity. (If a runtime `set_client_certificate` setter is ever added, it must clear `tls_sessions` and the TCP client the way pin changes do — noted for the security review in batch 3.)
- MASQUE note: the client certificate authenticates the **origin** (inner) TLS session; the outer proxy hop stays server-auth-only. If proxy-facing mTLS is ever wanted it is a separate knob.

### (e) Proxies — no new fields; the rhttp union is deliberately not ported

- `proxy_url: Option<String>` + `proxy_authorization: Option<String>` remain the entire proxy surface. Precedence stays exactly today's: **set ⇒ that proxy for both transports (MASQUE/CONNECT-UDP on H3, HTTP CONNECT via reqwest on TCP); unset ⇒ no proxy on both transports, never the environment** (the `no_proxy()` else-branch at `tcp.rs:536-540` stays load-bearing).
- Why the per-scheme/multi shape dies here: Vane rejects non-`https` request URLs outright (`lib.rs:1756`, `tcp.rs:789`, `tcp.rs:1204`). rhttp's `ProxyCondition{onlyHttp, onlyHttps, all}` discriminates on request scheme — with exactly one possible scheme, `onlyHttp` can never match and `onlyHttps`≡`all`. rhttp's `.list(...)` semantics are "first scheme-match wins" — with one scheme that is always element 0, i.e. a single proxy, i.e. `proxy_url`. Porting the union would add three types and an FFI array that cannot ever change behavior. If Vane ever accepts `http://` (it should not), the union becomes meaningful and can be added then as new appended config fields.
- SOCKS stays out: Vane's https-only proxy rule (`lib.rs:1067`) is a security posture (CONNECT target + authorization exposure), and MASQUE on H3 has no SOCKS analogue — a socks5 knob would be TCP-only and silently dead on H3. Rejected for the same reason as the TLS-version-on-H3 trap.
- ABI consequence: **zero layout change for (e)**; it rides the existing `proxy_url`/`proxy_authorization` struct members and config-parse path.

### (f) DNS resolver — a client method, not a config field

```rust
#[uniffi::export(with_foreign)]
pub trait VaneDnsResolver: Send + Sync {
    /// Return IP address literals for `host` ("203.0.113.7", "2001:db8::1").
    /// No ports, no hostnames.
    ///
    /// Threading, per binding — know your thread before you block:
    /// - Dart: a native worker thread paired with a worker isolate; the main
    ///   isolate is never blocked by requests.
    /// - Swift/Kotlin, H3 path: the CALLER's thread of the sync `execute`
    ///   (lib.rs:1093) — possibly the platform main thread on iOS.
    /// - Swift/Kotlin, TCP path: reqwest's internal runtime thread, via
    ///   spawn_blocking (3f) — never the caller's thread.
    ///
    /// Rules: must not invoke Vane requests (deadlock — it runs on the thread
    /// that owns the in-flight request); must not block on work scheduled on
    /// the platform main thread, because on iOS the callback may itself be
    /// running there (sync-execute case above).
    fn resolve(&self, host: String) -> Vec<String>;
}

#[uniffi::export]
impl VaneClient {
    /// Set or clear the resolver. Clears the cached TCP client AND drains the
    /// H3 connection pool and any warmup state — same lifecycle as a pin
    /// change — so no pooled connection resolved under the old resolver (or
    /// no resolver) survives the switch.
    pub fn set_dns_resolver(&self, resolver: Option<Arc<dyn VaneDnsResolver>>);
}
```

- **Not a config field**, for one structural reason with three faces: a callback cannot ride `VaneClientConfig`. (1) The Dart config crosses the C ABI as a plain `#[repr(C)]` struct — a Dart closure has no representation there. (2) Keeping the UniFFI record data-only avoids depending on interface-in-record support and keeps the record trivially constructible in the JVM-only Kotlin tests. (3) The reqwest client already has a rebuild-on-change lifecycle (pins, `tcp.rs:552-563`) that a setter slots into. One mechanism, all three bindings symmetric.
- **Sync, not async — justified**: on the H3 path the core's resolution is a synchronous call on the request's thread (`resolve_peer_addr`, `lib.rs:4466`, called from `lib.rs:1621/1767/2053`); the blocking system call `to_socket_addrs` is what the callback replaces there. On the TCP path the adapter wraps the same sync chain in `tokio::task::spawn_blocking` (3f), restoring exactly hyper `GaiResolver`'s threading semantics — the blocking call runs on the blocking pool, never on reqwest's shared runtime thread. An async UniFFI trait would force async plumbing into a sync core for no behavioral gain. Kotlin/Swift implementers that want async internally can block their own resolve call, subject to the trait-doc threading rules above.
- **Precedence: `dns_overrides` (exact host match) → resolver → system.** Overrides win because they are the more specific, deterministic instruction, they are what `h3_offline`/pinning test rigs depend on unconditionally, and they cost a map lookup. Stated in every binding's doc comment.
- **Error semantics — no silent drops (anti-rhttp-defect)**: any returned entry that fails `IpAddr` parse → the whole resolution fails with `Transport("dns resolver returned an invalid address for {host}")`; empty list → `Transport("dns resolver returned no addresses for {host}")`. No fallback to system on resolver failure — a misconfigured resolver fails loudly, it does not silently degrade. First address wins (matches today's `.next()`); port always from the URL. `dns_overrides` stays `HashMap<String, String>` — widening to multi-address buys nothing while `.next()` takes the first anyway; widen if Happy Eyeballs ever lands.
- Dart mechanism (C ABI): request-id rendezvous, full spec in §4. The MethodChannel fallback path does **not** support the resolver (no sane callback transport there); `setDnsResolver` on the method-channel platform implementation throws `UnsupportedError` — loud, and FFI is the default instance (`vane_flutter_platform_interface.dart:11`).

### (g) `VaneResponse.remote_ip: Option<String>` — appended, `#[uniffi(default = None)]`

- IP literal only, no port, no brackets (`"203.0.113.7"`, `"2001:db8::1"`) — rhttp `remoteIp` parity. Port is known on both paths; add a `remote_port` later only on demand.
- **Definition: the socket peer of the connection that produced the final hop's response.** Direct H3: the resolved origin (`peer_addr`). H3 via MASQUE: **the proxy** (`outer.peer_addr`) — because on TCP via CONNECT, reqwest's `remote_addr()` can only ever report the actual socket peer (the proxy), and cross-transport consistency beats per-transport cleverness. Documented on the field. Redirects: the final hop's connection.
- Parity-plus: populated on H3 (Vane owns the quiche socket); rhttp's is null there.

### (h) `VaneResponse.headers` becomes `Vec<VaneHeader>`; `set_cookie` is dropped

Breaking change, taken deliberately (packages unpublished; the brief allows it; it simplifies):

```rust
pub struct VaneResponse {
    pub status_code: u16,
    /// Ordered (name, value) pairs, names lowercased, duplicates preserved,
    /// set-cookie inline in arrival position. On H3 this is wire order; on
    /// TCP it is reqwest HeaderMap order (duplicates of a name grouped).
    pub headers: Vec<VaneHeader>,          // WAS HashMap<String, String>
    pub body: Vec<u8>,
    pub body_file_path: Option<String>,
    pub is_success: bool,
    pub url: String,
    #[uniffi(default = None)] pub http_version: Option<VaneHttpVersion>,
    #[uniffi(default = None)] pub remote_ip: Option<String>,   // NEW, last
    // set_cookie: REMOVED — derivable: headers.filter(name == "set-cookie")
}
```

- The lossy `", "` join in `merge_header` (`lib.rs:5451-5471`) is deleted; `ResponseState` accumulates the ordered list. `location` keeps **all** occurrences in the list as data; redirect logic reads the *first* occurrence via a `first_header_value(&headers, "location")` helper — behavior identical to today's first-wins rule. The `content-length` hook fires on the first occurrence.
- `set_cookie` field is dropped rather than kept redundant: the C ABI already ships set-cookie as repeated pairs (`ffi_header_array_from`, `lib.rs:6677-6702`, emitting positional order from batch 2 instead of re-expanding at the tail); UniFFI carried it separately only because the map couldn't. One representation; every consumer gets a derived view (section 2).
- Derived map view semantics, chosen on purpose: **first-wins** (matches reqwest `HeaderMap::get`, matches Vane's existing `location` rule; rhttp's last-wins is incidental, not principled). Consumers that must see every duplicate use the list itself, or on Dart the `headerMapList` multimap view (section 2) — which is what the dio adapter consumes, since a first-wins map would silently drop duplicate non-set-cookie headers dio currently receives comma-joined.
- **Non-ASCII header values are never dropped** (anti-rhttp-defect): TCP builds values with `String::from_utf8_lossy(v.as_bytes())` instead of skipping on `to_str()` failure; H3 already decodes lossily. A garbled byte becomes U+FFFD, not a vanished header.

---

## 2. PER-BINDING API

Names are the UniFFI camelizations of the field names — identical across Swift/Kotlin/Dart. One builder method (or Dart ctor param) per knob.

### Swift — `VaneClient+Extension.swift` (`VaneConfigurationBuilder`, :1076)

```swift
public func maxRedirects(_ value: UInt32) -> VaneConfigurationBuilder
public func tlsMinVersion(_ value: VaneTlsVersion) -> VaneConfigurationBuilder
public func tlsMaxVersion(_ value: VaneTlsVersion) -> VaneConfigurationBuilder
public func customRootCertificates(_ pems: [String]) -> VaneConfigurationBuilder
public func clientCertificate(certificatePem: String, privateKeyPem: String) -> VaneConfigurationBuilder

// response conveniences (extension VaneResponse):
public var headerMap: [String: String]   // first value wins
public var setCookie: [String]           // headers where name == "set-cookie", in order
```

```swift
let config = VaneConfigurationBuilder()
    .maxRedirects(5)
    .tlsMinVersion(.tls13)
    .customRootCertificates([corpRootPem])
    .clientCertificate(certificatePem: certPem, privateKeyPem: keyPem)
    .build()
let client = try VaneClient(config: config)
client.setDnsResolver(resolver: MyResolver())   // class MyResolver: VaneDnsResolver

let resp = try client.get(url: "https://internal.example")
print(resp.remoteIp ?? "-", resp.headerMap["content-type"] ?? "-")
```

### Kotlin — `VaneClient.kt` (`VaneConfigurationBuilder`, :1007)

```kotlin
fun maxRedirects(value: UInt): VaneConfigurationBuilder
fun tlsMinVersion(value: VaneTlsVersion): VaneConfigurationBuilder
fun tlsMaxVersion(value: VaneTlsVersion): VaneConfigurationBuilder
fun customRootCertificates(pems: List<String>): VaneConfigurationBuilder
fun clientCertificate(certificatePem: String, privateKeyPem: String): VaneConfigurationBuilder

// response conveniences (extension vals in the same hand file):
val VaneResponse.headerMap: Map<String, String>   // first value wins
val VaneResponse.setCookie: List<String>
```

```kotlin
val client = VaneClient(
    VaneConfigurationBuilder()
        .maxRedirects(5u)
        .tlsMinVersion(VaneTlsVersion.TLS13)
        .customRootCertificates(listOf(corpRootPem))
        .clientCertificate(certPem, keyPem)
        .build()
)
client.setDnsResolver(object : VaneDnsResolver {
    override fun resolve(host: String): List<String> = listOf("192.0.2.10")
})
```

### Dart — `vane_flutter.dart` (`VaneConfiguration` ctor params, all optional)

```dart
enum VaneTlsVersion { tls12, tls13 }
class VaneClientCertificate {
  final String certificatePem, privateKeyPem;
  const VaneClientCertificate({required this.certificatePem, required this.privateKeyPem});
}

// VaneConfiguration gains:
final int maxRedirects;                       // default 10
final VaneTlsVersion? tlsMinVersion;          // default null
final VaneTlsVersion? tlsMaxVersion;          // default null
final List<String> customRootCertificates;    // default const []
final VaneClientCertificate? clientCertificate; // default null
// toMap(): 'maxRedirects', 'tlsMinVersion' ('tls12'/'tls13'), 'tlsMaxVersion',
//          'customRootCertificates', 'clientCertificate': {'certificatePem':…, 'privateKeyPem':…}

// VaneClient gains:
Future<void> setDnsResolver(Future<List<String>> Function(String host)? resolver);

// VaneResponse model — all three rhttp views (headers/headerMap/headerMapList):
final List<(String, String)> headers;         // WAS Map<String, String>
Map<String, String> get headerMap;            // first value wins
Map<String, List<String>> get headerMapList;  // multimap: ALL duplicates, in order
List<String> get setCookie;
final String? remoteIp;
```

```dart
final client = await Vane.createClient(VaneConfiguration(
  maxRedirects: 5,
  tlsMinVersion: VaneTlsVersion.tls13,
  customRootCertificates: [corpRootPem],
  clientCertificate: VaneClientCertificate(certificatePem: certPem, privateKeyPem: keyPem),
));
await client.setDnsResolver((host) async => ['192.0.2.10']);
```

`headerMapList` ships on Dart because the dio adapter needs the multimap (below); Swift/Kotlin twins are a one-line extension each, added on demand.

`vane_flutter_dio`: no config touch point — the adapter wraps an already-configured `VaneClient` (recon §1e). Response-model change (h) reaches its response translation: the adapter folds the pair list into dio's `Map<String, List<String>>` via `headerMapList`, **preserving ALL duplicates** — using the first-wins `headerMap` here would silently drop duplicate non-set-cookie headers that today arrive comma-joined, a regression; the multimap fold is the correct translation and makes the adapter a one-liner. `remoteIp` passes through to dio extras if exposed at all (not required for parity).

MethodChannel plugins — **two touch-point groups**, both named so neither is discovered late:
- Config direction (batch 1): one `configFromMap` line per scalar knob (`VaneFlutterPlugin.swift:109`, `VaneFlutterPlugin.kt:106`); `clientCertificate` read as a nested `{certificatePem, privateKeyPem}` map; `customRootCertificates` as a string list. `setDnsResolver` on this path throws `UnsupportedError` (see 1f).
- Response direction (batch 2): the plugins serialize the response map — `VaneFlutterPlugin.swift:241` (`"headers": headers`) and `:250` (`"setCookie": setCookie`), plus the Kotlin twin — both must emit the ordered pair list (list of `[name, value]` or `{name, value}` maps) and `remoteIp`, and drop the separate `setCookie` entry; the Dart method-channel platform implementation's response parser changes in the same commit to consume the pair list + `remoteIp`. Both plugins and the parser move together or the method-channel path silently mis-parses.

---

## 3. CORE WIRING

Per knob, both paths. Anything a stack cannot do is named here, not discovered later.

### (a) max_redirects
- `next_redirect_url` (`lib.rs:5127`): the `hops >= MAX_REDIRECTS` check (`:5138`) takes `max_redirects` as a parameter (the function already takes `hops`).
- `RedirectChain::run` (`lib.rs:2458`): `redirect_possible: … && hops < max_redirects` (`:2491`); value comes from the client config at the two entry points (`follow_http3_redirects` `:1353`, `_streaming` `:1420`).
- TCP: `follow_and_read` (`tcp.rs:1062`) → `redirect_target` (`tcp.rs:1406`) — same shared function, same parameter. reqwest's own follower stays `Policy::none()` (`tcp.rs:481`); Vane keeps driving hops by hand for the cookie/header reasons documented there.
- The `MAX_REDIRECTS` const is deleted (single source of truth: config). `MAX_INTERMEDIATE_BODY_BYTES` stays a const — not part of this item.

### (b) tls_min/max_version
- **TCP**: `build_tls` (`tcp.rs:352-404`): replace `.with_safe_default_protocol_versions()` (`tcp.rs:375`) with `.with_protocol_versions(&versions)` where `versions` is `[&rustls::version::TLS12, &rustls::version::TLS13]` filtered by min/max. ALPN (`tcp.rs:397-401`) untouched.
- **H3**: no call exists to make — quiche hardcodes 1.3 in `Handshake::init`, per connection, regardless of how the SSL context was built (so the 3c/3d ctx-builder path changes nothing here). Construction-time validation (1b) is the entire H3 story. A doc comment at the quiche config site (`lib.rs:4345`) says so, pointing at the validation.
- `PoolKey::new` (`lib.rs:2601`): add both fields.

### (c) custom_root_certificates

- **TCP — OR-composite verifier, uniform on all platforms** (replaces the refuted per-platform `new_with_extra_roots`, which does not exist on Android):
  ```rust
  // tcp.rs — sits where inner_verifier's result goes today (tcp.rs:408-416);
  // PinnedServerCertVerifier (tcp.rs:84) wraps THIS, unchanged above it.
  struct ExtendedTrustVerifier {
      platform: Arc<rustls_platform_verifier::Verifier>,
      custom: Arc<rustls::client::WebPkiServerVerifier>, // over the parsed custom roots
  }
  impl ServerCertVerifier for ExtendedTrustVerifier {
      fn verify_server_cert(&self, ...) -> Result<ServerCertVerified, Error> {
          match self.platform.verify_server_cert(...) {
              Ok(v) => Ok(v),
              Err(platform_err) => self.custom.verify_server_cert(...)
                  .map_err(|_| platform_err), // both failed → report the platform error
          }
      }
      // verify_tls12_signature / verify_tls13_signature / supported_verify_schemes:
      // delegate to self.platform (chain-independent signature checks).
  }
  ```
  - Accept if **either** arm accepts; each arm is a full verifier (chain + name + validity over its own roots), so OR-composition is exactly extend semantics and cannot widen beyond the union. Built only when the list is non-empty — empty list keeps today's bare `Verifier::new(provider)`, zero change.
  - `WebPkiServerVerifier::builder(root_store).build()` over roots parsed once at client construction via `CertificateDer::pem_slice_iter`.
  - Precedent: verifier-wrapping is already how pins work (`PinnedServerCertVerifier`, `tcp.rs:84`); this is one more layer beneath it. The `#[cfg(test)]` `inner_verifier` twin (`tcp.rs:425-449`) composes the same way.
  - **Android is a first-class target of this mechanism** — named in batch-3 scope and the security-review gate; the instrumented custom-roots test beside `TcpTrustStoreInstrumentedTest` is the device-real tripwire.
- **H3 — in-memory via the boring ctx builder, no files** (replaces the refuted temp-file mechanism): when `custom_root_certificates` is non-empty (or a client certificate is set, 3d), `create_quiche_config` (`lib.rs:4345`) builds the config with `quiche::Config::with_boring_ssl_ctx_builder(PROTOCOL_VERSION, builder)` (`quiche-0.29.1/src/lib.rs:644`, default feature `boringssl-boring-crate`, boring 4.22.0 already linked) instead of `Config::new`:
  - Platform roots: `load_platform_roots` (`lib.rs:4415`) is refactored to *discover* the CA file-or-directory path (its existing candidate lists + `directory_has_certs` stay verbatim) and both consumers load it — the plain path via quiche's `load_verify_locations_from_*` as today, the builder path via `SslContextBuilder::load_verify_locations(ca_file, ca_path)` (boring `ssl/mod.rs:1338`, the same `SSL_CTX_load_verify_locations`). Same discovery, same store, no drift.
  - Custom roots: `X509::stack_from_pem(concatenated_pem)` → `builder.cert_store_mut().add_cert(x509)` per cert (boring `ssl/mod.rs:1788`, `x509/store.rs:86`) — **strictly additive** on top of the platform roots, memory only.
  - The `#[cfg(test)]` `h3_offline` test-CA seam (`lib.rs:4359-4364`) rides the same additive shape on whichever path is active.
  - `from_boring` delta (`tls/mod.rs:136-160`, verified): relative to `Context::new()` it calls `set_session_callback()` (so `TlsSessionStore` resumption keeps working) and skips only `load_ca_certs()` — which vane's `load_platform_roots` supersedes on both paths anyway. Nothing else to replicate. TLS 1.3 pinning survives via `Handshake::init` (per-connection, `tls/mod.rs:381-382`).
  - When neither (c) nor (d) is set: today's `Config::new` path, byte-for-byte unchanged.
  - `QuicConfigCache` is per-client and config is immutable → the `(idle_timeout, udp_payload)` key needs no change; the PEM inputs live on the client (1d hygiene note) so every cache-miss rebuild has them.
- Pins: no wiring change anywhere — both hook sites run after/independently of root trust.
- Revocation asymmetry (documented, accepted): the custom arm is pure webpki with no revocation checking — on Apple/Windows a chain the platform arm rejects as revoked is accepted by the custom arm if the custom roots also anchor it.

### (d) client_certificate
- **TCP**: `tcp.rs:382` `.with_no_client_auth()` becomes `.with_client_auth_cert(chain, key)` when set (chain/key parsed at construction, held as `Vec<CertificateDer>` + `PrivateKeyDer`). rustls errors at build → surfaced from `VaneClient::new`/first TCP build as `Tls`.
- **H3**: the same ctx-builder path as 3c, in memory end to end: chain via `X509::stack_from_pem(certificate_pem)` → `builder.set_certificate(&chain[0])` (`ssl/mod.rs:1454`) + `builder.add_extra_chain_cert(cert)` for each intermediate (`ssl/mod.rs:1463`); key via `PKey::private_key_from_pem(key_pem)` (`pkey.rs:389`) → `builder.set_private_key(&key)` (`ssl/mod.rs:1493`). **No temp files, no disk writes, ever.** The PEM strings are retained on the client (key as `Zeroizing<String>`, 1d) because the builder runs per `QuicConfigCache` miss.
- `PoolKey::new`: add the cert fingerprint (Option<String>, SHA-256 of certificate_pem).

### (e) proxies
- No wiring change. `MasqueProxyConfig::parse` (`lib.rs:3418`), `connect_http3_via_proxy` (`lib.rs:2046`), reqwest proxy block (`tcp.rs:515-541`) all untouched.

### (f) dns_resolver
- New client field: `dns_resolver: Mutex<Option<Arc<dyn VaneDnsResolver>>>`. `set_dns_resolver` stores it, clears `tcp_client` (the pin-change rebuild path, `tcp.rs:552-563`), **and drains the H3 connection pool plus any warmup state** — a pooled H3 connection was resolved under the previous resolver and `PoolKey` carries no resolver identity, so drain-on-set is the only thing that keeps "set after first request" honest (same defect class as risk b2, now closed at the setter). "Set it before the first request" remains the documented fast path; setting it later is correct, just costs the pools.
- **H3 + warmup + proxy resolution**: `resolve_peer_addr` (`lib.rs:4466`) gains a `resolver: Option<&dyn VaneDnsResolver>` parameter, consulted between the override map and `to_socket_addrs`, with the hard-error semantics of 1f. Call sites `lib.rs:1621`, `:1767`, `:2053`, warmup probe `tcp.rs:~615`. Proxy addresses resolve through the same chain (consistent with dns_overrides applying to the proxy today, `lib.rs:2053`).
- **TCP**: a `struct ResolverAdapter(Arc<dyn VaneDnsResolver>)` implementing `reqwest::dns::Resolve` (`reqwest-0.13.4/src/dns/resolve.rs:21`): `resolve(name)` returns `Box::pin(async move { tokio::task::spawn_blocking(move || /* sync chain: overrides → callback */).await … })` — the rendezvous/callback **must not run inline in the future**: reqwest's blocking client polls all in-flight requests on one shared current_thread runtime, and an inline blocking resolve (up to the 10 s Dart rendezvous timeout) would head-of-line-block every concurrent TCP request *and* park the tokio timer so request timeouts couldn't fire. `spawn_blocking` (tokio is already in the graph via reqwest) restores exactly today's hyper `GaiResolver` semantics, which uses the same blocking pool for `getaddrinfo`. Yields `SocketAddr`s with port 0 (reqwest takes the URL port — same trick as `builder.resolve`, `tcp.rs:505-513`). Installed via `ClientBuilder::dns_resolver` (blocking builder, `blocking/client.rs:1195`). When no resolver is set, the existing per-host `builder.resolve` loop stays — no adapter, zero change to today's path. Overrides are checked first inside the adapter too, so both transports share one decision chain and cannot diverge.
- Reentrancy + threading: documented in the trait doc (1f) — per-binding thread reality, no Vane requests from the callback, no blocking on main-thread work.

### (g) remote_ip
- **H3**: `Http3ResponseParts` (`lib.rs:2778-2787`) gains `remote_ip: Option<String>`; filled in `execute_hop` from the in-scope `peer_addr` (`lib.rs:1767`) for direct connections and from `outer.peer_addr` for MASQUE (`lib.rs:2103`); `into_public_response` (`lib.rs:2790`) copies it out. `streaming_head` (`lib.rs:2897`) same.
- **TCP**: one line at `tcp.rs:846-848`, next to the existing `http_version_of` capture (which the recon confirmed runs **before** `read_body` moves the response): `let remote_ip = hop.response.remote_addr().map(|a| a.ip().to_string());` — then into the `VaneResponse` at `tcp.rs:857-867`. Through a CONNECT proxy reqwest reports the socket peer (the proxy) — consistent with the H3 MASQUE definition by construction.

### (h) header list
- `ResponseState` (`lib.rs:5451`): `headers: HashMap` + `set_cookie_headers: Vec` collapse into `headers: Vec<(String, String)>` with a `push_header` that lowercases (H3 already lowercase via QPACK) and appends. `first_header_value` helper serves `location` (redirect logic) and the `content-length` hook. Internal cookie-jar consumers read the filtered set-cookie view.
- `ffi_header_array_from` (`lib.rs:6677`): emits the list verbatim in order (drops the tail re-expansion of set_cookie). C signature unchanged.
- TCP response construction (`tcp.rs:857`): iterate `HeaderMap::iter()` into pairs, `from_utf8_lossy` on values.

---

## 4. ABI — one bump, v4 → v5, landed whole in batch 1

`vane_ffi_abi_version()` (`lib.rs:5955-5972`): `4` → `5`; the doc-comment history gains a v5 entry naming everything below. `vane_flutter/lib/vane_flutter_ffi.dart:321` `_expectedAbiVersion`: `4` → `5` in the same change-set (the two constants move together, `TODO.md:99-101`) — **lockstep is load-bearing in v5, not just convention**: v5 changes the `vane_ffi_client_create` signature (4c), so a stale library on either side would corrupt the call frame; the ABI check must run before the first create call, as it does today. The v5 **contract** — struct layouts *and* symbol inventory — is fully specified here, so later batches fill in behavior without ever moving the number again.

### 4a. `VaneFfiClientConfig` (`lib.rs:5807`) — six members appended after `proxy_authorization`, in this exact order

```rust
    // -------- appended in ABI v5; order is offset --------
    /// Redirect hop cap; callers pass 10 for the default. Values > 64 are
    /// rejected by ffi_config.
    pub max_redirects: u32,
    /// 0 = unset, 12 = TLS 1.2, 13 = TLS 1.3. Anything else is an error.
    pub tls_min_version: u8,
    pub tls_max_version: u8,
    // 2 bytes tail padding here before the next 8-aligned pointer — deliberate;
    // do NOT fill them later without a bump (the VaneFfiResponse padding lesson).
    /// Concatenated PEM bundle; empty = none. Becomes a one-element
    /// custom_root_certificates vec in the core (PEM is concatenation-safe).
    pub custom_root_ca_pem: VaneFfiString,
    /// PEM leaf-first chain; empty = none. Must be set together with the key.
    pub client_certificate_pem: VaneFfiString,
    pub client_private_key_pem: VaneFfiString,
```

`ffi_config` (`lib.rs:6493`) additions: read all six; new decoder twin `ffi_tls_version(value: u8) -> Result<Option<VaneTlsVersion>, String>` next to `ffi_protocol_mode` (`lib.rs:6566`), mapping 0/12/13 and erroring otherwise; cert-pem set XOR key-pem set → `Err("clientCertificate requires both certificatePem and privateKeyPem")`. Null config pointer still means `VaneClientConfig::default()` — unchanged.

Dart mirror (`vane_flutter_ffi.dart:39-101`), appended in the same order with explicit annotations:

```dart
  @Uint32() external int maxRedirects;
  @Uint8()  external int tlsMinVersion;   // 0 unset, 12, 13
  @Uint8()  external int tlsMaxVersion;
  external _VaneFfiString customRootCaPem;
  external _VaneFfiString clientCertificatePem;
  external _VaneFfiString clientPrivateKeyPem;
```

`_NativeConfig` (`vane_flutter_ffi.dart:2005`): `maxRedirects = config['maxRedirects'] as int? ?? 10`; `_tlsVersionByte(String?)` twin of `ffi_tls_version`; roots joined with `'\n'` into one `_NativeString`; cert/key as two more `_NativeString`s — all three added to `free()`.

### 4b. `VaneFfiResponse` (`lib.rs:5879`) — one member appended after `error`

```rust
    /// IP literal of the socket peer ("203.0.113.7"); empty = unknown.
    /// Appended in ABI v5 — the padding after is_success was spent in v3
    /// (http_version, error_kind), so this GROWS the struct.
    pub remote_ip: VaneFfiBuffer,
```

Filled by `ffi_response_from_vane` (`lib.rs:6436`); `ffi_error_response` (`lib.rs:6452`) sets it empty. Dart mirror (`vane_flutter_ffi.dart:166-186`): `remoteIp` declared **last**, after `error` — the file's own comment about declaration-order-is-offset applies. Freed wherever the other buffers are freed.

Header-array contract strengthened in the v5 doc text (no layout change), **explicitly effective from batch 2** — batch 1 ships the layout while `ffi_header_array_from` still emits the v4 tail-expanded shape, so the doc entry reads "from batch 2 of the v5 rollout": entries are in arrival order, duplicates preserved, `set-cookie` in positional order (previously re-expanded at the tail). Consumers must not assume unique keys — already the documented rule (`lib.rs:6674-6676`).

### 4c. Changed + new exported symbols (part of the v5 contract)

**Changed — `vane_ffi_client_create` (`lib.rs:5969-5988`) gains a typed-error out-param** (closes the Dart kind-loss asymmetry: today `ffi_create_client` flattens with `error.to_string()` at `lib.rs:6308-6310` and Dart throws `VaneHttpException` with `kind: unknown`, `vane_flutter_ffi.dart:1702-1711` / `vane_flutter.dart:352-355`, while Swift/Kotlin get typed `VaneError.InvalidRequest`):

```rust
/// v5: `out_error_kind` (nullable; ignored when null) receives the
/// `VaneError::ffi_kind` code on failure — the SAME code table the response
/// path already uses and Dart's `_errorKind` already decodes
/// (InvalidRequest = 1). Written only when creation fails.
pub extern "C" fn vane_ffi_client_create(
    config: *const VaneFfiClientConfig,
    out_error: /* unchanged */,
    out_error_kind: *mut u32,          // NEW in v5
) -> /* handle, unchanged */;
```

Dart: the create call passes a `Uint32` out-param and maps it through the existing `_errorKind` decoder, so a validation failure throws `VaneHttpException` with `VaneErrorKind.invalidRequest` — parity with Swift/Kotlin. Wired in **batch 1** (the validation it surfaces lands there). This signature change is the concrete reason the `_expectedAbiVersion` lockstep note in §4's opening paragraph is mandatory, not advisory.

**New — DNS rendezvous symbols (stubs in batch 1, wired in batch 4):**

```rust
/// Callback type: invoked on a Vane worker thread. `host` points into memory
/// owned by the pending-request registry and stays valid until the request id
/// is retired (reply received, or client destroyed) — safe for Dart's
/// NativeCallable.listener asynchronous delivery.
type VaneFfiDnsResolveCallback =
    extern "C" fn(request_id: u64, host: VaneFfiString, user_data: *mut c_void);

/// Install/replace/clear (callback = None) the resolver for a client.
pub extern "C" fn vane_ffi_set_dns_resolver(
    client: /* same handle type ffi_create_client returns */,
    callback: Option<VaneFfiDnsResolveCallback>,
    user_data: *mut c_void,
) -> bool;

/// Complete a resolution. `ips`: newline-separated IP literals, UTF-8;
/// `is_error` true (or an empty list) fails the resolution loudly.
/// Unknown/expired request ids are a safe no-op.
pub extern "C" fn vane_ffi_dns_resolver_reply(
    request_id: u64,
    ips: VaneFfiString,
    is_error: bool,
);
```

Native rendezvous (batch 4): a per-client registry `Mutex<HashMap<u64, PendingResolve>>` + condvar. The worker thread inserts the entry (owning the host string), invokes the callback, and parks with a **10 s timeout** (fixed; make it a knob only if someone asks). On the TCP path this parking happens inside `spawn_blocking` (3f), never on reqwest's runtime thread. `reply` fills the slot and wakes. **Timeout does not free the entry** — it is tombstoned and freed when the late reply arrives or the client is destroyed, so a slow Dart isolate can never cause a use-after-free on the host pointer; the registry is capped (drop-oldest-tombstone) like `MAX_TLS_SESSIONS`. Timeout → `Transport("dns resolver timed out for {host}")`.

Dart side (batch 4): one `NativeCallable.listener` per client (`keepIsolateAlive: false`), closed in `client.close()`; the listener schedules the user's `Future` and calls `vane_ffi_dns_resolver_reply` from the isolate. Why the eight knobs need exactly this and nothing more: only resolution *returns a value to native*; every other knob is data marshaled client→native at construction. Everything except (f) and (g) rides the config-parse path or an existing array shape — which is why one struct-append set + one signature change + two symbols is the whole v5 surface.

### 4d. Regeneration + checksum blind spot

Adding record fields and changing `VaneResponse.headers` moves **no** UniFFI function checksum (`scripts/release-build.sh:17-21`); `create_default_config` stays 54371. The only guards are the CI staleness diff and the same-commit rebuild rule. Every batch below therefore ends with: `make build_kotlin` (NDK 27.0.12077973, ends in `check_so_links`), `make build_swift`, `make build_swift_small`, the Swift bindgen step from `scripts/release-build.sh:24-33`, and **re-applying the FfiConverterString BOM hand-patch** (`VaneClient.swift:482-495` and `:507-511`) — all in the same commit as the vane-rs change.

---

## 5. BATCHES

### Batch 1 — plumbing: maxRedirects, TLS versions, proxies decision, full v5 layout
Scope: all five core config fields + `VaneTlsVersion` + `VaneClientCertificate` types land (UniFFI record grows once; the manual redacting `Debug` lands with the type, §1); (a) and (b) fully wired; (c)/(d) fields **parsed and rejected** by `VaneClient::new` with `InvalidRequest("customRootCertificates is not implemented yet")` (loud, no silent no-op) until batch 3; v5 bump with the complete 4a/4b layout **and the `vane_ffi_client_create` `out_error_kind` signature change, wired end-to-end** (its validation source exists from this batch); DNS symbols exported as stubs (`set_dns_resolver` returns false / `reply` no-ops); `MAX_REDIRECTS` const deleted; PoolKey additions; (e) documented as resolved-no-change.
Tests:
- `default_config_uses_http3_only` (`lib.rs:6942`) extended: `max_redirects == 10`, both TLS versions `None`. Hermetic; pins the defaults table.
- New construction-validation tests beside `plaintext_proxies_are_rejected_for_both_transports` (`lib.rs:7157`): cap >64 rejected; min>max rejected; `tls_max == Tls12` with H3-capable mode rejected (and accepted with `Http2ThenHttp1`); not-implemented guards fire. Hermetic.
- New `ffi_config_round_trips_every_field` — builds a fully-populated `VaneFfiClientConfig` and asserts the parsed `VaneClientConfig` field-by-field; **closes the recon's named gap** (no `ffi_config` test exists). Model: `ffi_body_stream_symbols_round_trip_with_kinds` (`lib.rs:8915`). Hermetic; pins the C parse layer.
- New `ffi_client_create_reports_error_kind` — invalid config through `vane_ffi_client_create` writes `1` (InvalidRequest) to `out_error_kind`, and a null `out_error_kind` is safe. Hermetic; pins the 4c contract. Dart twin in the real-library group: bad config → `VaneHttpException` with `kind == VaneErrorKind.invalidRequest`, not `unknown`.
- Redirect cap: h3_offline chain test — server issues 3 hops, `max_redirects = 2` → `REDIRECT_REFUSED_HOP_CAP`; `max_redirects = 3` → success. TCP twin in `tcp/tests.rs`. Hermetic; pins shared-decision behavior on both transports.
- TLS enforcement: `tls_min_13_refuses_a_tls12_only_server` in `tcp/tests.rs` (local rustls server pinned to 1.2 via the TEST_ROOT harness). Hermetic; pins the one real enforcement site.
- Kotlin: `VaneClientConfig` RustBuffer wire-order lower/lift test beside `VaneResponseFfiRoundTripTest` (recon's suggested home). JVM, hermetic; pins UniFFI field order.
- Dart: first-ever assertion on `MockVaneFlutterPlatform.lastConfiguration` (`vane_flutter_test.dart:22` — written, never read): `toMap()` carries `maxRedirects`/`tlsMinVersion`. Hermetic; pins the Dart map layer. Plus ABI-guard test update to `ABI v5` (`vane_flutter_ffi_test.dart:85-101`).
Rebuild step per 4d, same commit.

### Batch 2 — response shape: header list + remote_ip behavior
Scope: (h) core rework (`ResponseState`, three `VaneResponse` construction sites, `ffi_header_array_from` — the 4b positional-order contract becomes true here), (g) population on both paths, binding response models + derived views (Swift/Kotlin `headerMap`/`setCookie`; Dart `headerMap`/`headerMapList`/`setCookie`), **MethodChannel response serialization on BOTH plugins** (`VaneFlutterPlugin.swift:241` headers + `:250` setCookie → ordered pair list + `remoteIp`, and the Kotlin twin) **plus the Dart method-channel platform parser** for the pair list + `remoteIp` (same commit — the two ends of that channel cannot land apart), and the `vane_flutter_dio` response translation via the `headerMapList` multimap fold (§2 — first-wins would drop duplicates dio gets today).
Tests:
- Proptests rewritten for list semantics: `check_merge_headers` / `merged_headers_follow_the_fold_rules` (`proptests.rs:557`, `:811`) become order-preservation + duplicate-preservation + first-location invariants. Hermetic; release is `panic=abort`, so these stay the crash gate.
- `remote_ip_is_the_socket_peer`: h3_offline asserts `127.0.0.1`; `tcp/tests.rs` twin. MASQUE selection (`outer.peer_addr`) unit-tested at the selection point (no hermetic MASQUE server exists; the live-proxy check stays advisory). Hermetic + one unit.
- Kotlin `VaneResponseFfiRoundTripTest`: updated wire format — headers as `List<VaneHeader>`, no `set_cookie`, `remote_ip` last. JVM, hermetic; pins the new RustBuffer layout.
- Dart real-library group (`vane_flutter_ffi_test.dart`): duplicate `set-cookie` arrives as two ordered pairs; `remoteIp` non-null against the local server. Hermetic (self-skipping without libvane).
- Dart model tests: `headerMap` first-wins AND `headerMapList` keeps both values of a duplicated non-set-cookie header, in order — the multimap is what guards the dio adapter. Plus a `vane_flutter_dio` adapter test: a response with a duplicated header reaches dio as `Map<String, List<String>>` with **both** values.
- MethodChannel round-trip (mock channel): plugin-shaped response map with pair-list headers + `remoteIp` parses into the same `VaneResponse` model the FFI path produces. Hermetic; pins the two-ends-move-together rule.
- Swift `VaneSwiftTests`: `headerMap`/`setCookie` derived-view semantics (first-wins) — pure model test, hermetic.
Rebuild step per 4d — **this is the batch where the checksum blind spot bites hardest** (record layout changed, no checksum moved): all four artifact sets in the same commit, small XCFramework included.

### Batch 3 — trust: custom roots + mTLS (security-review gate before merge)
Scope: replace batch-1 rejection guards with real wiring (3c, 3d): the **OR-composite `ExtendedTrustVerifier` on TCP, uniform on all platforms — Android explicitly in scope** (it is the platform that forced the composite; there is no platform extra-roots API there); the **in-memory boring ctx-builder path on H3** (`with_boring_ssl_ctx_builder`, roots via `cert_store_mut`, chain via `set_certificate`/`add_extra_chain_cert`, key via `set_private_key` — no temp files anywhere); `with_client_auth_cert` on TCP; `load_platform_roots` refactor to shared discovery (3c).
Security review gate (blocking, before merge), updated for the new mechanisms: pins still fail-closed with custom roots present (composite sits beneath `PinnedServerCertVerifier`); the composite cannot accept a chain neither arm fully verifies (each arm is a complete verifier; signature methods delegate to platform); **Android composite behavior device-verified** (instrumented tripwire below); pins⇒no-resumption untouched; **no key bytes on disk anywhere** (grep-level check: no fs writes in the 3c/3d paths), key held as `Zeroizing`, redacting `Debug` in force; no PEM/key material in any error or log (redaction tests); ctx-builder parity — the only `Context::new()` vs `from_boring` delta is `load_ca_certs`, superseded by `load_platform_roots`, and `set_session_callback` is preserved (verified `tls/mod.rs:136-160`) so H3 session resumption still works, which matters because resumption skips cert verification (memory note) — confirm the resumption gates are unchanged.
Tests:
- `custom_root_extends_platform_trust`: `tcp/tests.rs` — server cert from a fresh CA *not* in TEST_ROOT; fails without the knob, passes with it (exercises the composite's custom arm). h3_offline twin: feed the test CA through `custom_root_certificates` instead of the `#[cfg(test)]` seam, proving the production ctx-builder path end-to-end. Hermetic; pins the additive semantics.
- `custom_roots_do_not_bypass_pins`: pinned host + custom root that would otherwise validate → still `VaneError::Tls`. Hermetic; pins the security property.
- `custom_roots_do_not_widen_trust`: with custom roots configured, a server cert from a *third*, unknown CA still fails on BOTH stacks (the OR must be a union, not "anything goes"). Hermetic.
- `client_certificate_debug_is_redacted`: `format!("{:?}", config)` with populated `client_certificate` contains no `-----BEGIN`/key material; the fingerprint may appear. Hermetic; pins the manual Debug impl.
- mTLS: `tcp/tests.rs` — local rustls server requiring a client cert: refused without the knob, accepted with it; wrong key rejected at construction. H3: h3_offline server demands a client cert if the harness allows; otherwise the ctx-builder assembly is unit-tested (config with chain+key builds a quiche Config successfully, from memory, no fs access) and the handshake test is live-advisory. Hermetic core + one gap named honestly.
- H3 resumption through the builder path: with custom roots set (builder path active), the existing session-resumption test shape still resumes — guards the `set_session_callback` preservation.
- Construction validation: malformed chain/key PEM → `InvalidRequest`, message content asserted material-free. Hermetic.
- Kotlin instrumented (`androidTest`): custom-roots case beside `TcpTrustStoreInstrumentedTest` — **the device-real tripwire for the composite on Android**: a custom CA trusted via the knob validates against a local server on-device while a stranger CA still fails. This test existing and passing is the gate's Android line item.
Rebuild step per 4d, same commit.

### Batch 4 — DNS resolver callback (last; the only cross-language-callback machinery)
Scope: core trait + `set_dns_resolver` (clears `tcp_client` **and drains the H3 pool + warmup state**, 3f) + `resolve_peer_addr` chain + reqwest `ResolverAdapter` with the **`spawn_blocking` bridge** (3f — the rendezvous never runs on reqwest's shared runtime thread); fill the v5 stub symbols with the rendezvous; Dart `NativeCallable.listener` plumbing; builder/docs (per-binding threading doc, 1f). No ABI bump — v5 already includes the symbols.
Tests:
- Core, hermetic (Rust fake resolver, h3_offline): override beats resolver; resolver consulted when no override; garbage IP → hard `Transport` error (no silent drop); empty list → error; resolver never called for override-hit hosts.
- Setter lifecycle, pin-change style: `set_dns_resolver` after a pooled H3 request → pool drained (next request re-resolves through the new resolver; assert the new resolver is consulted, not the pooled connection reused) and `tcp_client` cleared. Pins the drain-on-set rule.
- TCP adapter: `tcp/tests.rs` — resolver steers a fake hostname to the local listener; port-0 behavior pinned. Plus a concurrency check: one slow resolver call (sleep in the fake) does not stall a concurrent TCP request to an already-resolved host and does not suppress that request's timeout — pins the `spawn_blocking` bridge (the head-of-line refutation, now a regression test).
- Dart real-library group: rendezvous reply round-trip; timeout → clean `Transport` error; **late reply after timeout is a safe no-op (no crash)**; client close with a resolution in flight. These four pin the only genuinely dangerous machinery in the whole item.
- Kotlin instrumented + Swift test: a recorded-host resolver asserting `resolve("…")` was invoked with the URL host and its address was used (local server). Kotlin JVM tests untouched (trait is object-side, not record-side — by design, 1f).
Rebuild step per 4d, same commit.

---

## 6. RISKS — what can silently not-work, and the test that catches it

| # | Risk | Catching test |
|---|---|---|
| a | Redirect cap enforced on one transport only (two `run` loops + tcp path share the function but pass different values) | the batch-1 h3_offline + tcp twin pair assert the same cap on both |
| b | **The classic**: `tlsMaxVersion = tls12` accepted, then H3 silently negotiates 1.3 anyway (quiche hardcodes it) | construction-rejection test: Tls12-max + H3-capable mode must error; `tls_min_13_refuses_a_tls12_only_server` proves TCP actually enforces |
| b2 | TLS versions omitted from PoolKey → pooled connection under old posture serves new-posture request (future-mutability trap) | PoolKey inclusion + the existing `quiche_config_is_cached_per_idle_timeout_and_udp_payload`-style keying test extended to PoolKey |
| c | Custom roots dead on one platform/transport — the exact hole the review found (no `new_with_extra_roots` on Android): a cfg'd or per-OS mechanism silently no-ops where the API is missing | the composite is uniform vane code (no per-OS branch to rot); the Android instrumented custom-roots case beside `TcpTrustStoreInstrumentedTest` is the device-real tripwire; the h3_offline twin trusts the test CA **via the knob**, proving the production ctx-builder path |
| c2 | Custom root accidentally widens a pinned host | `custom_roots_do_not_bypass_pins` |
| c3 | OR-composite bug widens trust beyond the union of the two root sets (e.g. a half-verifying arm) | `custom_roots_do_not_widen_trust`: third unknown CA still fails on both stacks with the knob set |
| c4 | Ctx-builder path drops something `Context::new()` used to provide (the `from_boring` delta) — most dangerously the session callback or CA loading | verified delta is exactly `load_ca_certs` (superseded by `load_platform_roots`); batch-3 resumption-through-builder-path test guards `set_session_callback`; `custom_root_extends_platform_trust` (h3 twin) guards root loading |
| d | mTLS wired on TCP only; H3 servers requiring a cert get a handshake failure with a misleading error | H3 mTLS test (or, if harness-limited, the named live-advisory + ctx-builder assembly unit); error-message assertion distinguishes "server requires client cert" |
| d2 | Key material leaked — in a log, an error, or a `Debug` dump (no files exist to leak by design: the H3 path is in-memory end to end) | `client_certificate_debug_is_redacted` + material-free-error assertions + the batch-3 gate's no-fs-writes check; `Zeroizing` covers process memory on drop |
| e | Someone later adds `http://` support and the proxy no-op union reasoning silently rots | not applicable now (nothing shipped); the https-only rejection tests at `lib.rs:1756`/`tcp.rs:789` are the tripwire — noted in the (e) decision record |
| f | Dart resolver deadlock/UAF: blocked worker + slow isolate, or timeout freeing the host string a late listener still reads | the four Dart rendezvous tests, esp. late-reply-after-timeout and close-with-in-flight |
| f2 | Resolver silently ignored on one path (reqwest adapter installed, `resolve_peer_addr` chain forgotten — or vice versa) | core hermetic tests run the same fake resolver through both an H3 and a TCP request |
| f3 | Resolver rendezvous blocks reqwest's shared runtime → head-of-line blocking of all concurrent TCP requests and parked timeout timers | the batch-4 concurrency test: slow resolve + concurrent request + live timeout — pins the `spawn_blocking` bridge |
| f4 | `set_dns_resolver` after first request leaves pooled H3 connections resolved under the old resolver (PoolKey has no resolver identity) | the batch-4 setter-lifecycle test: pool drained + tcp_client cleared, pin-change style |
| g | `remote_ip` null on one transport (rhttp's exact defect, inverted) or reading `remote_addr()` after `read_body` moved the response | h3_offline + tcp twins assert non-null 127.0.0.1; the capture-site comment pins ordering |
| g2 | MASQUE reports origin on H3 but proxy on TCP → cross-transport inconsistency | unit at the H3 selection point asserts `outer.peer_addr` |
| h | Stale small XCFramework after the `VaneResponse` layout change — **no checksum moves, no runtime guard; reads N+1 fields and traps on every response** (recon's blind spot, verbatim) | same-commit rebuild rule + CI staleness diff (`release.yml:65-67`); Kotlin RustBuffer round-trip test pins the new field order |
| h2 | A binding's derived `headerMap` picks a different winner (first vs last) than another's — or the dio adapter folds through first-wins and silently drops duplicate non-set-cookie headers | the per-binding derived-view tests all assert first-wins on the same duplicate-header fixture; the Dart `headerMapList` + dio adapter tests assert both duplicate values survive to dio |
| h3 | MethodChannel path mis-parses after (h)/(g): plugins serialize the new pair-list/`remoteIp` shape but the Dart parser (or one of the two plugins) lags | batch-2 same-commit rule for both plugins + parser; the mock-channel round-trip test |
| i | Dart loses the error kind on construction failure (`kind: unknown` while Swift/Kotlin get `InvalidRequest`) | `ffi_client_create_reports_error_kind` + the Dart real-library twin asserting `VaneErrorKind.invalidRequest` |
| all | Dart defaults drift from Rust defaults (the existing 4-vs-8 disease) | `default_config_uses_http3_only` (Rust) + the new `lastConfiguration`/`_NativeConfig` fallback assertions (Dart) pin the same numbers on both sides |
