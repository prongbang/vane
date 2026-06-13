# vane_flutter

Flutter bindings for Vane, backed by Dart FFI calls into the shared Rust
HTTP/3 core.

## Features

- HTTP/3-only requests through the shared Rust/quiche backend
- Stateful native clients for connection pooling and cookies
- Optional cookie persistence through `cookiePersistencePath`
- Production FFI transport that calls the typed Rust `vane_ffi_*` C ABI directly
- Dart request, response, and error interceptors
- Cancel tokens, upload/download progress polling, multipart bodies, upload
  from file, and download-to-file response streaming
- Optional retry, certificate pinning, DNS overrides, request limits, and
  response limits through `VaneConfiguration`
- Android support through packaged `libvane.so` artifacts
- iOS support through the bundled `RustFramework.xcframework`
- Legacy MethodChannel bindings remain available as an explicit fallback

Proxy configuration is exposed for API compatibility, but the current
HTTP/3-only backend rejects runtime proxy use until MASQUE/CONNECT-UDP support
is implemented.

## Usage

```dart
await Vane.configure(
  configuration: const VaneConfiguration(
    cookiesEnabled: true,
    cookiePersistencePath: '/tmp/vane-cookies.txt',
    connectionPoolEnabled: true,
    retryMaxAttempts: 2,
  ),
  requestInterceptors: [
    (request) => request.copyWith(
      headers: {...request.headers, 'accept': 'application/json'},
    ),
  ],
);

final response = await Vane.get(
  'https://cloudflare-quic.com',
  options: VaneRequestOptions(
    headers: {'accept': 'application/json'},
    onDownloadProgress: (received, total) {},
  ),
);

final created = await Vane.postJson(
  'https://api.example.com/users',
  {'name': 'Ada'},
);

await Vane.uploadFile(
  'https://api.example.com/upload',
  '/tmp/input.bin',
  options: VaneRequestOptions(onUploadProgress: (sent, total) {}),
);

final report = await Vane.download(
  'https://api.example.com/report',
  '/tmp/report.json',
);

await Vane.close();
```

For per-request control, keep using the builder API. It shares the same native
client and connection pool:

```dart
final client = VaneClient();

final fileResponse = await client
    .request('https://api.example.com/search')
    .queryParam('q', 'http3')
    .timeout(10)
    .downloadToFile('/tmp/search.json')
    .execute();

await client.close();
```

## Performance Usage

- Call `Vane.configure` once during app startup and reuse the shared client.
- Do not create a new `VaneClient` for every request; that loses connection
  pooling and cookie reuse.
- Use direct helpers such as `Vane.get`, `Vane.postJson`, `Vane.uploadFile`,
  and `Vane.download` for common requests.
- Use the builder API only when a request needs custom per-request options.
- Add interceptors to the shared client when auth/logging behavior changes;
  this keeps the native client and connection pool alive.
- Add progress callbacks only when the UI needs progress.
- Use `download` / `downloadToFile` for large responses.
- Current multipart helpers build the body in memory, so keep multipart for
  small/medium payloads.

```dart
Vane.addRequestInterceptor(
  (request) => request.copyWith(
    headers: {...request.headers, 'authorization': 'Bearer $token'},
  ),
);

Vane.addResponseInterceptor((response) => response);
Vane.clearInterceptors();
```

Android currently requires `minSdk = 33`, matching `VaneKotlin`.
