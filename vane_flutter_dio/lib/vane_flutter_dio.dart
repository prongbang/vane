import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:vane_flutter/vane_flutter.dart';

/// A dio [HttpClientAdapter] backed by Vane's HTTP/3 core, so an existing dio
/// stack — its interceptors, transformers and `FormData` — runs over Vane by
/// swapping one line.
///
/// ```dart
/// final dio = Dio()..httpClientAdapter = VaneDioAdapter();
/// final response = await dio.get<String>('https://example.com/');
/// dio.close();
/// ```
///
/// Requests made through this adapter appear in the DevTools Network tab like
/// any other Vane request — profiling is recorded in the platform layer, not
/// here.
///
/// Status validation stays with dio: the adapter reports whatever status the
/// core saw, and `validateStatus` turns it into [DioExceptionType.badResponse]
/// (including the 0 the core reports for a status it could not parse).
///
/// Known ceilings, all inherited from the core rather than introduced here:
/// - The core returns a complete response body, so [fetch] yields it as a
///   single chunk. Real chunked streaming needs an incremental read on the Rust
///   side; until then `ResponseType.stream` produces one chunk and
///   `onReceiveProgress` fires once, at 100%.
/// - The core takes a complete request body, so [fetch] collects
///   `requestStream` before the request starts. `onSendProgress` therefore
///   tracks buffering, not the wire.
/// - Request headers are flattened: dio carries `Map<String, dynamic>` where
///   the core takes one string per name, so an `Iterable` value is joined with
///   `', '` and a null value is dropped.
/// - Response headers are inflated the other way: the core returns one string
///   per name — repeated headers already comma-joined — so every entry becomes
///   a one-element list. `Headers.value()` reads normally; `Headers[name]`
///   returns that single joined element instead of N separate ones.
/// - `set-cookie` never appears in the response headers: the core routes it
///   into its own cookie jar and does not re-surface it. Session and auth
///   interceptors that read `set-cookie` themselves will see nothing — enable
///   Vane's cookie jar instead ([VaneConfiguration.cookiesEnabled]).
/// - The FFI response carries no reason phrase and no redirect chain, so
///   [ResponseBody.statusMessage] is left null, `isRedirect` stays false,
///   `redirects` stays null and [RequestOptions.maxRedirects] is ignored.
///   [RequestOptions.followRedirects] is honored.
/// - [RequestOptions.persistentConnection] is ignored: connection reuse is a
///   client-wide Vane setting, not a per-request one.
/// - `ResponseBody.extraKeyHttpVersion` is not set: the FFI response does not
///   say which protocol served the request, and with fallback enabled that is
///   not something the adapter can assume.
/// - dio's three timeout budgets collapse onto Vane's single whole-request
///   deadline, so the largest configured one wins (rounded up to whole
///   seconds). A shorter pick would abort requests dio's own adapter would
///   still be waiting on.
///
/// The `cancelFuture` dio hands to [fetch] is wired to a [VaneCancelToken] and
/// surfaces as [DioExceptionType.cancel]. One gap: the token only registers
/// with the core inside `execute`, so a cancel landing before that window does
/// not reach the native side — the request runs to completion and its response
/// is discarded, but the caller still sees a `cancel`.
class VaneDioAdapter implements HttpClientAdapter {
  /// Creates an adapter. Pass [client] to share an existing [VaneClient] — its
  /// configuration, interceptors and connection pool — in which case [close]
  /// leaves it open. Without one, a private [VaneClient] is created and closed
  /// together with this adapter.
  VaneDioAdapter({VaneClient? client})
    : _client = client ?? VaneClient(),
      _ownsClient = client == null;

  final VaneClient _client;
  final bool _ownsClient;
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) {
      _throwClosed();
    }

    VaneCancelToken? token;
    var cancelled = false;
    if (cancelFuture != null) {
      final cancelToken = token = VaneCancelToken();
      unawaited(
        cancelFuture
            .then((_) {
              cancelled = true;
              return cancelToken.cancel();
            })
            .catchError((Object _) {}),
      );
    }

    try {
      final body = requestStream == null ? null : await _collect(requestStream);
      // close() can land while the body is being collected; without this the
      // request would go on to open a fresh native client.
      if (_closed) {
        _throwClosed();
      }
      if (cancelled) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: null,
        );
      }

      final timeout = _timeoutOf(options);
      final builder = _client
          .request(options.uri.toString(), method: options.method)
          .headers(_requestHeaders(options.headers))
          .followRedirects(options.followRedirects);
      if (body != null && body.isNotEmpty) {
        builder.body(body);
      }
      if (token != null) {
        builder.cancelToken(token);
      }
      if (timeout > Duration.zero) {
        builder.timeout((timeout.inMilliseconds / 1000).ceil());
      }

      final VaneResponse response;
      try {
        response = await builder.execute();
      } on VaneHttpException catch (error) {
        // Trust the flag rather than the core's error text.
        if (cancelled) {
          throw DioException.requestCancelled(
            requestOptions: options,
            reason: error,
          );
        }
        throw _asDioException(error, options, timeout);
      }
      if (cancelled) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: null,
        );
      }

      return ResponseBody(
        // Single chunk over the zero-copy body view: no copy happens until dio
        // collects the stream.
        Stream<Uint8List>.value(response.body),
        response.statusCode,
        headers: <String, List<String>>{
          for (final header in response.headers.entries)
            header.key: <String>[header.value],
        },
      );
    } finally {
      await token?.dispose();
    }
  }

  /// The core takes a complete body, so the stream is drained up front rather
  /// than forwarded.
  static Future<Uint8List> _collect(Stream<Uint8List> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static Map<String, String> _requestHeaders(Map<String, dynamic> headers) {
    final flattened = <String, String>{};
    headers.forEach((name, value) {
      if (value == null) {
        return;
      }
      flattened[name] = value is Iterable ? value.join(', ') : '$value';
    });
    return flattened;
  }

  /// The longest of dio's three budgets, since Vane enforces one deadline over
  /// the whole request. [Duration.zero] means "no deadline configured".
  static Duration _timeoutOf(RequestOptions options) {
    var longest = Duration.zero;
    for (final budget in <Duration?>[
      options.connectTimeout,
      options.sendTimeout,
      options.receiveTimeout,
    ]) {
      if (budget != null && budget > longest) {
        longest = budget;
      }
    }
    return longest;
  }

  static DioException _asDioException(
    VaneHttpException error,
    RequestOptions options,
    Duration timeout,
  ) {
    final message = error.message;
    // ponytail: substring match on the core's English error text, because
    // VaneHttpException carries no structured error kind across the FFI
    // boundary. Upgrade path: a kind field on the FFI response / UniFFI error
    // record, matched here instead of the message.
    if (message.contains('timed out')) {
      // A handshake or MASQUE tunnel that never came up died before the
      // request went out; everything else timed out waiting on the peer.
      if (message.contains('handshake timed out') ||
          message.contains('establishment timed out')) {
        return DioException.connectionTimeout(
          timeout: timeout,
          requestOptions: options,
          error: error,
        );
      }
      return DioException.receiveTimeout(
        timeout: timeout,
        requestOptions: options,
        error: error,
      );
    }
    // Everything the core reports is a transport failure — DNS, QUIC, TLS,
    // I/O — plus the handful of plumbing errors the FFI layer raises itself.
    return DioException.connectionError(
      requestOptions: options,
      reason: message,
      error: error,
    );
  }

  Never _throwClosed() {
    throw StateError(
      "Can't establish connection after the adapter was closed.",
    );
  }

  @override
  void close({bool force = false}) {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_ownsClient) {
      // HttpClientAdapter.close() is synchronous; the native handle is released
      // in the background, and a failure there must not become an unhandled
      // error. [force] makes no difference: the core has no graceful-drain
      // mode, so either way the client closes now and in-flight requests fail.
      unawaited(_client.close().catchError((Object _) {}));
    }
  }
}
