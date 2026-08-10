# vane_flutter_dio

A [dio](https://pub.dev/packages/dio) `HttpClientAdapter` backed by
[`vane_flutter`](../vane_flutter)'s HTTP/3 core.

It lives beside `vane_flutter` rather than inside it so the base plugin does not
carry dio as a dependency for apps that do not use dio — the same split
`native_dio_adapter` uses.

## Usage

```dart
import 'package:dio/dio.dart';
import 'package:vane_flutter_dio/vane_flutter_dio.dart';

final dio = Dio()..httpClientAdapter = VaneDioAdapter();

final response = await dio.get<String>('https://example.com/');
print(response.statusCode);

dio.close();
```

Your interceptors, transformers, `FormData`, `CancelToken` and `validateStatus`
keep working; only the transport changes.

To share configuration — base URL, headers, certificate pins, cookie jar,
connection pool — with the rest of the app, pass an existing `VaneClient`:

```dart
final vane = VaneClient(
  configuration: const VaneConfiguration(cookiesEnabled: true),
);
final dio = Dio()..httpClientAdapter = VaneDioAdapter(client: vane);
```

An injected client outlives `close()`; a client the adapter created itself is
closed with it.

## Installing

```yaml
dependencies:
  vane_flutter_dio:
    path: ../vane_flutter_dio
```

Both this package and `vane_flutter` are repo-local, so the dependency is a
path. Publishing to pub.dev would mean replacing the `vane_flutter` path in
`pubspec.yaml` with a version constraint and removing `publish_to: none`.

## Ceilings

`VaneDioAdapter`'s doc comment carries the full list; the ones worth knowing up
front:

- Bodies are not streamed in either direction. The core takes a complete
  request body and returns a complete response body, so uploads are buffered
  before the request starts and the response arrives as a single chunk —
  `onSendProgress` tracks buffering rather than the wire, and
  `onReceiveProgress` fires once.
- Response headers come back one string per name — a name the server repeated
  arrives comma-joined (`'a, b'`), identically on both transports — so each
  becomes a one-element list. `set-cookie` is the exception: it arrives as a
  genuine N-element list, which is what dio's `cookie_manager` reads. Those values are raw — a cookie Vane's own jar
  refused (a public-suffix `Domain`, or an IP literal) still appears among
  them, so a third-party cookie store in front of this adapter admits what
  Vane deliberately rejected, and it does so even with
  `VaneConfiguration(cookiesEnabled: false)`.
- No reason phrase and no redirect chain come back over FFI, so
  `Response.statusMessage` is null, `isRedirect` is false and `maxRedirects` is
  ignored. `followRedirects` is honored.
- dio's `connectTimeout`, `sendTimeout` and `receiveTimeout` collapse onto
  Vane's single whole-request deadline: the largest configured one wins,
  rounded up to whole seconds.

## Testing

```sh
flutter test
```

The suite runs against a recording fake platform, so it needs no network and no
native library.
