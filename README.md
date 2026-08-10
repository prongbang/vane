# Vane

Vane is a cross-platform HTTP client powered by a shared Rust core and exposed
as native APIs for Android, iOS, and Flutter. The current production target is
small, fast, HTTP/3-only networking over QUIC.

## Current Transport

- HTTP/3 over QUIC through Cloudflare `quiche`
- HTTP/1.1 and HTTP/2 fallback code removed from the Rust core
- TLS 1.3 through the HTTP/3 transport
- HTTP/1.0 unsupported
- HTTP/3 proxying is supported through HTTPS MASQUE/CONNECT-UDP proxies
- Static DNS overrides are supported; dynamic DNS callback resolvers are not
  part of this production candidate

## Platform Packages

| Platform | Package | Minimum target | Notes |
| --- | --- | --- | --- |
| Android | `VaneKotlin/library` | `minSdk 33` | Kotlin coroutine API with packaged `libvane.so` files |
| iOS/macOS | `VaneSwift` | iOS 13, macOS 10.15 | Swift Package with `RustFramework.xcframework` |
| Flutter | `vane_flutter` submodule | Flutter 3.3+, Dart 3.12+ | Dart FFI by default, MethodChannel fallback kept available |

## Repository Setup

Clone the repository with submodules so every platform package is available:

```bash
git clone --recurse-submodules https://github.com/prongbang/vane.git
cd vane
```

If the repository was cloned without submodules, initialize them afterwards:

```bash
git submodule update --init --recursive
```

The current submodules are:

| Path | Repository |
| --- | --- |
| `vane-rs` | `https://github.com/prongbang/vane-rs` |
| `VaneSwift` | `https://github.com/prongbang/VaneSwift` |
| `VaneKotlin` | `https://github.com/prongbang/VaneKotlin` |
| `vane_flutter` | `https://github.com/prongbang/vane_flutter.git` |

When updating a submodule, commit and push the submodule repository first, then
commit the updated gitlink in this repository.

## Feature Matrix

| Feature | Android | iOS | Flutter |
| --- | --- | --- | --- |
| HTTP/3 requests | Yes | Yes | Yes |
| GET, POST, PUT, DELETE, PATCH | Yes | Yes | Yes |
| Headers and query params | Yes | Yes | Yes |
| Base URL | Yes | Yes | Yes |
| Timeouts and redirects | Yes | Yes | Yes |
| Connection pooling | Yes | Yes | Yes |
| Request/response/error interceptors | Yes | Yes | Yes |
| Optional retry policy | Yes | Yes | Yes |
| Certificate pinning | Yes | Yes | Yes |
| Static custom DNS overrides | Yes | Yes | Yes |
| Cookies | Yes | Yes | Yes |
| Cookie persistence | Yes | Yes | Yes |
| Text, JSON, form helpers | Yes | Yes | Yes |
| Multipart bodies | Yes | Yes | Yes |
| Upload from file path | Yes | Yes | Yes |
| Download response to file | Yes | Yes | Yes |
| Upload/download progress callbacks | Yes | Yes | Yes |
| Cancel token | Not yet high-level | Not yet high-level | Yes |
| Proxy | Unsupported for HTTP/3-only transport | Unsupported for HTTP/3-only transport | Unsupported for HTTP/3-only transport |

## Configuration Reference

All platforms map to the same Rust configuration model:

| Option | Meaning |
| --- | --- |
| `baseUrl` / `baseURL` | Base URL for relative request paths |
| `defaultHeaders` | Headers added to each request unless overridden |
| `dnsOverrides` / `dnsOverride` | Static host-to-IP mapping while preserving SNI/authority |
| `certificatePins` / `certificatePin` | Host-scoped `sha256/<spki>` or `sha256-cert/<der>` pins |
| `cookiesEnabled` | Enable the native cookie jar |
| `cookiePersistencePath` | Optional file path for cookie persistence |
| `connectionPooling` / `connectionPoolEnabled` | Reuse idle HTTP/3 connections |
| `maxIdleConnections` | Maximum idle pooled connections |
| `connectionIdleTimeoutSeconds` | Idle connection expiry |
| `retryMaxAttempts` / `retry` | Optional retry policy |
| `retryInitialDelayMillis` | Initial retry delay |
| `retryMaxDelayMillis` | Retry delay cap |
| `retryUnsafeMethods` | Allow retrying non-idempotent methods such as POST/PATCH |
| `maxRequestBodyBytes` | Request body limit |
| `maxResponseBodyBytes` | In-memory response body limit |
| `timeoutSeconds` / `timeout` | Request timeout |
| `followRedirects` | Follow redirects |
| `userAgent` | Default user agent |
| `protocolMode` | Keep `HTTP3_ONLY` / `http3Only`; legacy enum cases fail clearly |
| `proxyUrl`, `proxyAuthorization` | HTTPS MASQUE/CONNECT-UDP proxy URL and optional authorization |

## Performance Usage Rules

Use Vane as a long-lived client, not as a per-request object. The native client
owns connection pooling, cookies, retry state, and QUIC connection reuse, so
creating a new `VaneSession` or `VaneClient` for every request gives up the main
performance benefit.

- Create one `VaneSession` / `VaneClient` per API domain or dependency-injection
  scope and reuse it.
- Use direct helpers (`get`, `postJson`, `uploadFile`, `download`) for common
  requests.
- Use the builder API only when a request needs custom headers, query params,
  progress callbacks, multipart, timeouts, or download paths.
- Add interceptors to an existing session/client when auth or logging behavior
  changes. This does not recreate the native client, so connection pooling and
  cookies stay warm.
- Rotate certificate pins on the existing session/client when remote config or
  dynamic pinning changes. Vane clears the native connection pool after a pin
  update so future QUIC handshakes use the latest pins.
- Enable progress callbacks only for UI-visible uploads/downloads. Requests
  without progress callbacks avoid the polling work.
- Use `download` / `downloadToFile` for large responses to avoid keeping the
  full response body in memory.
- Use `uploadFile` / `bodyFile` for file uploads. Current upload-from-file still
  loads the file into memory inside the Rust core before sending, so very large
  uploads should wait for true streaming upload support.
- Use multipart for small and medium form/file payloads. Current multipart
  helpers build the multipart body in memory.

## Android Usage

### Add The Library

Use the `VaneKotlin/library` module or publish it to your internal Maven
repository. The library currently packages native `libvane.so` files under
`src/main/jniLibs`.

```kotlin
dependencies {
    implementation(project(":library"))
}
```

### Configure A Session

```kotlin
import com.inteniquetic.vanekotlin.*

val config = VaneConfigurationBuilder()
    .baseUrl("https://api.example.com")
    .defaultHeaders(mapOf("Accept" to "application/json"))
    .dnsOverride("api.example.com", "203.0.113.10")
    .certificatePin(
        "api.example.com",
        listOf(
            "sha256/<base64-spki-sha256>",
            "sha256-cert/<base64-cert-der-sha256>"
        )
    )
    .cookiesEnabled(true)
    .cookiePersistencePath(context.filesDir.resolve("vane-cookies.txt").path)
    .connectionPooling(enabled = true, maxIdleConnections = 8u, idleTimeoutSeconds = 30u)
    .retry(maxAttempts = 3u, initialDelayMillis = 100u, maxDelayMillis = 1_000u)
    .bodyLimits(
        maxRequestBodyBytes = 64u * 1024u * 1024u,
        maxResponseBodyBytes = 64u * 1024u * 1024u
    )
    .timeout(30u)
    .followRedirects(true)
    .userAgent("MyApp/1.0")
    .http3Only()
    .build()

val session = VaneSession(
    configuration = config,
    requestInterceptors = listOf { request ->
        request.copy(headers = request.headers + ("Authorization" to "Bearer $token"))
    },
    responseInterceptors = listOf { response ->
        response
    },
    errorInterceptors = listOf { throwable ->
        null
    }
)
```

Create `VaneSession` once, for example in your DI container or repository
layer, and reuse it for all requests to the same API host.

Add interceptors later without rebuilding the native client:

```kotlin
session
    .addRequestInterceptor { request ->
        request.copy(headers = request.headers + ("Authorization" to "Bearer $token"))
    }
    .addResponseInterceptor { response ->
        response
    }

session.clearInterceptors()
```

Update certificate pins later for dynamic pinning or key rotation:

```kotlin
session.setCertificatePins(
    "api.example.com",
    listOf("sha256/<new-base64-spki-sha256>", "sha256/<backup-pin>")
)

session.clearCertificatePins("api.example.com")
```

### Requests

```kotlin
val response = session.get("/users").validateStatus()
val text = response.text

val created = session.postJson("/users", mapOf("name" to "Ada"))
    .validateStatus()

val form = session.postForm(
    "/login",
    mapOf("email" to "ada@example.com", "password" to "secret")
)

val upload = session.uploadFile("/upload", "/data/user/0/app/files/input.bin")

val download = session.download(
    "/reports/latest",
    "/data/user/0/app/files/report.json",
    onDownloadProgress = { received, total -> }
)
```

### Builder API

```kotlin
val bytes = session.request("/search", HttpMethod.POST)
    .header("Accept", "application/json")
    .queryParam("q", "http3")
    .jsonBody(mapOf("page" to 1))
    .timeout(10u)
    .responseBytes()
```

### Multipart And Progress

```kotlin
val response = session.request("/upload", HttpMethod.POST)
    .multipart(
        fields = mapOf("title" to "avatar"),
        files = listOf(
            VaneMultipartFile(
                fieldName = "photo",
                bytes = imageBytes,
                fileName = "me.jpg",
                contentType = "image/jpeg"
            )
        )
    )
    .onUploadProgress { sent, total -> }
    .onDownloadProgress { received, total -> }
    .execute()
```

### Cancel Token

```kotlin
VaneCancelToken().use { token ->
    val job = launch {
        try {
            session.request("/slow")
                .cancelToken(token)
                .execute()
        } catch (error: VaneException.Cancelled) {
            // request aborted
        }
    }

    token.cancel() // safe from any thread
    job.join()
}
```

The native token is created eagerly, so `cancel()` always reaches the core
immediately. A cancelled token stays cancelled, so reuse on a second request
aborts that one too. `close()` (here via `use`) releases the native token;
double-close and cancel-after-close are safe no-ops.

## iOS Usage

### Add The Package

Add `VaneSwift` through Swift Package Manager. The package exposes the
`VaneSwift` library and bundles `RustFramework.xcframework`.

> Upgrading past 2026-08-03: each XCFramework slice now keeps its header at
> `Headers/vaneFFI/vaneFFI.h` instead of `headers/RustFramework/vaneFFI.h`
> (cargo-swift 0.11 moved it; the module name `vaneFFI` and the bundle name
> `RustFramework` are unchanged, so SwiftPM consumers need no edit). Only a
> checked-in Xcode project that names the old header path directly has to
> change. On a case-insensitive filesystem git reports the twelve replacements
> as untracked additions beside twelve deletions, so stage the XCFramework
> directories explicitly — `git add -u` alone commits the deletions and drops
> the headers, leaving an XCFramework that fails `#if canImport(vaneFFI)`.

```swift
.package(path: "../VaneSwift")
```

```swift
.product(name: "VaneSwift", package: "VaneSwift")
```

### Configure A Session

```swift
import VaneSwift

let config = VaneConfigurationBuilder()
    .baseURL("https://api.example.com")
    .defaultHeaders(["Accept": "application/json"])
    .dnsOverride(host: "api.example.com", ipAddress: "203.0.113.10")
    .certificatePin(host: "api.example.com", pins: [
        "sha256/<base64-spki-sha256>",
        "sha256-cert/<base64-cert-der-sha256>"
    ])
    .cookiesEnabled(true)
    .cookiePersistencePath(
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vane-cookies.txt")
            .path
    )
    .connectionPooling(enabled: true, maxIdleConnections: 8, idleTimeoutSeconds: 30)
    .retry(maxAttempts: 3, initialDelayMillis: 100, maxDelayMillis: 1_000)
    .bodyLimits(
        maxRequestBodyBytes: 64 * 1024 * 1024,
        maxResponseBodyBytes: 64 * 1024 * 1024
    )
    .timeout(30)
    .followRedirects(true)
    .userAgent("MyApp/1.0")
    .http3Only()
    .build()

let session = try VaneSession(
    configuration: config,
    requestInterceptors: [
        { request in
            var request = request
            request.headers["Authorization"] = "Bearer \(token)"
            return request
        }
    ],
    responseInterceptors: [
        { response in response }
    ],
    errorInterceptors: [
        { error in nil }
    ]
)
```

Create `VaneSession` once, for example as an app service or API client
singleton, and reuse it for all requests to the same API host.

Add interceptors later without rebuilding the native client:

```swift
session
    .addRequestInterceptor { request in
        var request = request
        request.headers["Authorization"] = "Bearer \(token)"
        return request
    }
    .addResponseInterceptor { response in
        response
    }

session.clearInterceptors()
```

Update certificate pins later for dynamic pinning or key rotation:

```swift
try session.setCertificatePins(
    host: "api.example.com",
    pins: ["sha256/<new-base64-spki-sha256>", "sha256/<backup-pin>"]
)

try session.clearCertificatePins(host: "api.example.com")
```

### Requests

```swift
let response = try await session.get("/users").validateStatus()
let text = response.text

let created = try await session.postJSON("/users", ["name": "Ada"])
    .validateStatus()

let form = try await session.postForm(
    "/login",
    fields: ["email": "ada@example.com", "password": "secret"]
)

let upload = try await session.uploadFile(
    "/upload",
    path: "/tmp/input.bin",
    onUploadProgress: { sent, total in }
)

let download = try await session.download(
    "/reports/latest",
    to: "/tmp/report.json",
    onDownloadProgress: { received, total in }
)
```

### Builder API

```swift
struct User: Codable {
    let id: String
    let name: String
}

let users = try await session.request("/users")
    .header("Accept", "application/json")
    .queryParam("page", "1")
    .timeout(10)
    .responseJSON([User].self)

let raw = try await session.request("/upload", method: .post)
    .bodyFile("/tmp/input.bin")
    .downloadToFile("/tmp/upload-result.json")
    .execute()
```

### Multipart And Progress

```swift
let response = try await session.request("/upload", method: .post)
    .multipart(
        fields: ["title": "avatar"],
        files: [
            VaneMultipartFile(
                fieldName: "photo",
                data: imageData,
                fileName: "me.jpg",
                contentType: "image/jpeg"
            )
        ]
    )
    .onUploadProgress { sent, total in }
    .onDownloadProgress { received, total in }
    .execute()
```

### Cancel Token

```swift
let token = VaneCancelToken()

Task {
    do {
        _ = try await session.request("/slow")
            .cancelToken(token)
            .execute()
    } catch VaneError.Cancelled {
        // request aborted
    }
}

token.cancel() // safe from any thread
```

The native token is created eagerly, so `cancel()` always reaches the core
immediately. A cancelled token stays cancelled, so reuse on a second request
aborts that one too. The token releases its native entry in `deinit` — keep it
alive while the request is in flight, since a request whose token has been
deallocated keeps running but can no longer be cancelled.

## Flutter Usage

### Add The Package

Use the `vane_flutter` submodule as a local package, or publish it to your
package registry.

```yaml
dependencies:
  vane_flutter:
    path: ../vane_flutter
```

### Configure The Shared Client

```dart
import 'dart:typed_data';
import 'package:vane_flutter/vane_flutter.dart';

await Vane.configure(
  configuration: const VaneConfiguration(
    baseUrl: 'https://api.example.com',
    defaultHeaders: {'accept': 'application/json'},
    dnsOverrides: {'api.example.com': '203.0.113.10'},
    certificatePins: {
      'api.example.com': [
        'sha256/<base64-spki-sha256>',
        'sha256-cert/<base64-cert-der-sha256>',
      ],
    },
    cookiesEnabled: true,
    cookiePersistencePath: '/tmp/vane-cookies.txt',
    connectionPoolEnabled: true,
    maxIdleConnections: 8,
    connectionIdleTimeoutSeconds: 30,
    retryMaxAttempts: 3,
    retryInitialDelayMillis: 100,
    retryMaxDelayMillis: 1000,
    maxRequestBodyBytes: 64 * 1024 * 1024,
    maxResponseBodyBytes: 64 * 1024 * 1024,
    timeoutSeconds: 30,
    followRedirects: true,
    userAgent: 'MyApp/1.0',
    protocolMode: VaneProtocolMode.http3Only,
  ),
  requestInterceptors: [
    (request) => request.copyWith(
      headers: {...request.headers, 'authorization': 'Bearer $token'},
    ),
  ],
  responseInterceptors: [
    (response) => response,
  ],
  errorInterceptors: [
    (error, stackTrace) => null,
  ],
);
```

Call `Vane.configure` once during app startup, then use `Vane.get`,
`Vane.postJson`, `Vane.uploadFile`, and `Vane.download` throughout the app. Use
an explicit `VaneClient` only when you need a separate configuration or isolated
cookie/pool state.

Add interceptors later without rebuilding the native client:

```dart
Vane.addRequestInterceptor(
  (request) => request.copyWith(
    headers: {...request.headers, 'authorization': 'Bearer $token'},
  ),
);

Vane.addResponseInterceptor((response) => response);
Vane.clearInterceptors();
```

Update certificate pins later for dynamic pinning or key rotation:

```dart
await Vane.setCertificatePins('api.example.com', [
  'sha256/<new-base64-spki-sha256>',
  'sha256/<backup-pin>',
]);

await Vane.clearCertificatePins('api.example.com');
```

### Requests

```dart
final response = await Vane.get(
  '/users',
  options: const VaneRequestOptions(
    queryParams: {'page': '1'},
    timeoutSeconds: 10,
  ),
);

final created = await Vane.postJson('/users', {'name': 'Ada'})
    .then((response) => response.validateStatus());

final form = await Vane.postForm('/login', {
  'email': 'ada@example.com',
  'password': 'secret',
});

await Vane.uploadFile(
  '/upload',
  '/tmp/input.bin',
  options: VaneRequestOptions(
    onUploadProgress: (sent, total) {},
  ),
);

final downloaded = await Vane.download(
  '/reports/latest',
  '/tmp/report.json',
  options: VaneRequestOptions(
    onDownloadProgress: (received, total) {},
  ),
);

await Vane.close();
```

### Cancel Token

```dart
final token = VaneCancelToken();

final future = Vane.get(
  '/slow',
  options: VaneRequestOptions(cancelToken: token),
);

// Safe at any point, including before the request reaches the core: the
// intent is latched and replayed as soon as the token registers.
await token.cancel();
try {
  await future;
} on VaneHttpException catch (error) {
  assert(error.kind == VaneErrorKind.cancelled);
}
await token.dispose();
```

A cancelled token stays cancelled until it is disposed, so an undisposed token
passed to a second request aborts that one too. `dispose()` clears the latch as
well as the native id, so disposing in a `finally` — as both adapters do — makes
the token safe to reuse.

### Builder API

```dart
final client = VaneClient();

final result = await client
    .request('/search', method: 'POST')
    .header('accept', 'application/json')
    .queryParam('q', 'http3')
    .jsonBody({'page': 1})
    .timeout(10)
    .responseJson<Map<String, Object?>>();

await client.close();
```

### Multipart

```dart
final response = await Vane.request('/upload', method: 'POST')
    .multipart(
      fields: {'title': 'avatar'},
      fileParts: [
        VaneMultipartFile(
          fieldName: 'photo',
          fileName: 'me.jpg',
          contentType: 'image/jpeg',
          bytes: Uint8List.fromList(imageBytes),
        ),
      ],
    )
    .execute();
```

## Certificate Pinning

Pins are configured per host. Supported formats:

- `sha256/<base64-spki-sha256>` for SPKI SHA-256 pins
- `sha256-cert/<base64-cert-der-sha256>` for certificate DER SHA-256 pins

Configure at least two pins per host for rotation. Pin mismatch fails closed.

## Cookies

Cookies are disabled by default. Enable `cookiesEnabled` to use the native jar.
Set `cookiePersistencePath` to persist cookies across app restarts.

## Retry Policy

Retries are disabled by default because `retryMaxAttempts` is `1`. Increase it
to enable retry with exponential backoff. Unsafe methods such as POST and PATCH
are not retried unless `retryUnsafeMethods` is enabled.

## Upload And Download Behavior

- `body` sends in-memory bytes
- `bodyFilePath` / `bodyFile` uploads from a file path
- `responseBodyPath` / `downloadToFile` streams the response body to a file
- Android, iOS, and Flutter expose upload/download progress callbacks and
  cancel tokens

## Build And Verification

From the repository root:

```bash
(cd vane-rs && cargo fmt)
(cd vane-rs && cargo test --release)
(cd vane-rs && cargo clippy --release --all-targets -- -D warnings)
# Rebuild the native artifacts whenever vane-rs changes. Skipping these is how
# a stale libvane.so or a stale small-profile libvane.a ships: adding a UniFFI
# record field does not move a function checksum, so nothing at load time
# notices, and the Kotlin/Swift unit tests below never load them.
(cd vane-rs && make build_swift)
(cd vane-rs && make build_swift_small)
(cd vane-rs && make build_kotlin)   # needs ANDROID_NDK_HOME
swift test --package-path VaneSwift
./gradlew -p VaneKotlin :library:testDebugUnitTest
(cd vane_flutter && flutter test)
```

Full release verification:

```bash
./scripts/release-build.sh
```

Live HTTP/3 tests require an endpoint that really supports HTTP/3:

```bash
cd vane-rs
VANE_TEST_BASE_URL=https://<http3-enabled-host> cargo test --release
cd ..
VANE_TEST_BASE_URL=https://<http3-enabled-host> swift test --package-path VaneSwift
```

## Known Limitations

- HTTP/3 only; HTTP/1.1 and HTTP/2 are intentionally removed
- Proxy support requires an HTTPS MASQUE/CONNECT-UDP proxy; classic HTTP CONNECT
  proxies are not supported for QUIC
- Dynamic DNS callback resolvers are not implemented
- Response metadata: the negotiated protocol is available as
  `VaneResponse.httpVersion`, and `Set-Cookie` as `VaneResponse.setCookie`.
  Remote IP is still future work. Repeated non-cookie headers are comma-joined
  into one `"a, b"` value (RFC 9110 §5.2), identically on both transports;
  `set-cookie` alone stays a real list, via `VaneResponse.setCookie`
