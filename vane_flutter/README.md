# vane_flutter

Flutter bindings for Vane, backed by the same Rust HTTP/3 core used by
`VaneSwift` and `VaneKotlin`.

## Features

- HTTP/3-only requests through the shared Rust/quiche backend
- Stateful native clients for connection pooling and cookies
- Dart request, response, and error interceptors
- Optional retry, certificate pinning, DNS overrides, request limits, and
  response limits through `VaneConfiguration`
- Android support through the existing `VaneKotlin` source and native
  `jniLibs`
- iOS support through the existing `VaneSwift` package and
  `RustFramework.xcframework`

Proxy configuration is exposed for API compatibility, but the current
HTTP/3-only backend rejects runtime proxy use until MASQUE/CONNECT-UDP support
is implemented.

## Usage

```dart
final client = VaneClient(
  configuration: const VaneConfiguration(
    cookiesEnabled: true,
    connectionPoolEnabled: true,
    retryMaxAttempts: 2,
  ),
  requestInterceptors: [
    (request) => request.copyWith(
      headers: {...request.headers, 'accept': 'application/json'},
    ),
  ],
);

final response = await client
    .request('https://cloudflare-quic.com')
    .responseString();

await client.close();
```

Android currently requires `minSdk = 33`, matching `VaneKotlin`.
