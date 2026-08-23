import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:vane_flutter/vane_flutter.dart';
import 'package:vane_flutter/vane_flutter_platform_interface.dart';
import 'package:vane_flutter_dio/vane_flutter_dio.dart';

/// Records what the adapter hands to the platform and replays a canned
/// response, so the dio contract can be checked without a network.
class _RecordingPlatform
    with MockPlatformInterfaceMixin
    implements VaneFlutterPlatform {
  Map<String, Object?>? lastRequest;
  int closedClients = 0;
  Object? failWith;

  /// Holds [execute] open so a test can act while a request is in flight.
  Completer<void>? gate;
  VaneResponse response = VaneResponse(
    statusCode: 201,
    headers: const <(String, String)>[
      ('content-type', 'text/plain'),
      ('x-multi', 'a'),
      ('x-multi', 'b'),
    ],
    body: Uint8List.fromList(utf8.encode('hello')),
    isSuccess: true,
    url: 'https://example.com/thing',
  );

  @override
  Future<int> createClient(Map<String, Object?> configuration) async => 1;

  @override
  Future<VaneResponse> execute(int handle, Map<String, Object?> request) async {
    lastRequest = request;
    await gate?.future;
    final error = failWith;
    if (error != null) {
      throw error;
    }
    return response;
  }

  @override
  Future<void> closeClient(int handle) async {
    closedClients += 1;
  }

  @override
  Future<VaneStreamingResponse> executeStreaming(
    int handle,
    Map<String, Object?> request,
  ) {
    // The dio adapter buffers every response today; nothing routes here.
    throw UnimplementedError('streaming is not used by the dio adapter');
  }

  @override
  Future<void> setCertificatePins(
    int handle,
    String host,
    List<String> pins,
  ) async {}

  @override
  Future<void> warmup(int handle, String? url) async {}

  @override
  Future<int> createCancelToken() async => 1;

  @override
  Future<void> cancelToken(int id) async => cancelledTokens.add(id);
  final List<int> cancelledTokens = <int>[];

  @override
  Future<void> freeCancelToken(int id) async {}

  @override
  Future<int> createProgress() async => 1;

  @override
  Future<VaneProgress> progressSnapshot(int id) async => const VaneProgress(
    uploadSent: 0,
    uploadTotal: 0,
    downloadReceived: 0,
    downloadTotal: 0,
    done: true,
  );

  @override
  Future<void> freeProgress(int id) async {}
}

Future<Uint8List> _drain(Stream<Uint8List> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

void main() {
  late _RecordingPlatform fake;
  late VaneClient vane;
  late VaneDioAdapter adapter;

  setUp(() {
    fake = _RecordingPlatform();
    vane = VaneClient(platform: fake);
    adapter = VaneDioAdapter(client: vane);
  });

  test('fetch passes url, method and headers through to the core', () async {
    final response = await adapter.fetch(
      RequestOptions(
        path: 'https://example.com/thing?page=1',
        headers: <String, dynamic>{
          'accept': 'text/plain',
          // dio allows repeated headers and nulls; the core takes neither.
          'x-list': <String>['one', 'two'],
          'x-dropped': null,
        },
      ),
      null,
      null,
    );

    expect(fake.lastRequest?['url'], 'https://example.com/thing?page=1');
    expect(fake.lastRequest?['method'], 'GET');
    final headers = fake.lastRequest?['headers'] as Map<String, String>;
    expect(headers['accept'], 'text/plain');
    expect(headers['x-list'], 'one, two');
    expect(headers.containsKey('x-dropped'), isFalse);
    expect(fake.lastRequest?['followRedirects'], true);
    expect(fake.lastRequest?['body'], isNull);
    expect(fake.lastRequest?['timeoutSeconds'], isNull);

    expect(response.statusCode, 201);
    expect(response.statusMessage, isNull, reason: 'no reason phrase over FFI');
    expect(response.isRedirect, isFalse);
    expect(response.headers['content-type'], <String>['text/plain']);
    // BOTH values of the duplicated header reach dio, in arrival order — a
    // first-wins fold here would silently drop what dio gets today.
    expect(response.headers['x-multi'], <String>['a', 'b']);
    expect(response.headers, isNot(contains('set-cookie')));
    expect(
      response.extra,
      isNot(contains(HttpClientAdapter.extraKeyHttpVersion)),
      reason: 'an unknown protocol omits the key, as dio\'s own adapter does',
    );
    expect(utf8.decode(await _drain(response.stream)), 'hello');
  });

  test(
    'set-cookie stays a real multi-value list and the protocol is set',
    () async {
      fake.response = VaneResponse(
        statusCode: 200,
        headers: const <(String, String)>[
          ('content-type', 'text/plain'),
          ('set-cookie', 'a=1; Path=/'),
          ('set-cookie', 'b=2; Path=/'),
        ],
        body: Uint8List(0),
        isSuccess: true,
        url: 'https://example.com/thing',
        httpVersion: VaneHttpVersion.http2,
      );

      final body = await adapter.fetch(
        RequestOptions(path: 'https://example.com/thing'),
        null,
        null,
      );

      // Two entries, not one joined string: this is what dio's cookie_manager
      // reads, and joining would be unsplittable (Expires contains a comma).
      expect(body.headers['set-cookie'], <String>[
        'a=1; Path=/',
        'b=2; Path=/',
      ]);
      expect(body.extra[HttpClientAdapter.extraKeyHttpVersion], '2.0');

      // The multimap handed to dio is built fresh, not aliased into the
      // response. dio's `Headers.add`/`remove` mutate the stored list in
      // place, so aliasing would throw `UnsupportedError` here on a
      // fixed-length list and silently rewrite the caller's response on a
      // growable one.
      final headers = Headers.fromMap(body.headers);
      headers.add('set-cookie', 'c=3; Path=/');
      expect(headers['set-cookie'], hasLength(3));
      expect(fake.response.setCookie, hasLength(2));
    },
  );

  test('the request stream is collected into the core body', () async {
    await adapter.fetch(
      RequestOptions(path: 'https://example.com/thing', method: 'POST'),
      Stream<Uint8List>.fromIterable(<Uint8List>[
        Uint8List.fromList(utf8.encode('name=')),
        Uint8List.fromList(utf8.encode('vane')),
      ]),
      null,
    );

    expect(fake.lastRequest?['method'], 'POST');
    expect(fake.lastRequest?['body'], utf8.encode('name=vane'));
  });

  test("dio's three budgets collapse onto one core deadline", () async {
    await adapter.fetch(
      RequestOptions(
        path: 'https://example.com/thing',
        connectTimeout: const Duration(seconds: 2),
        sendTimeout: const Duration(milliseconds: 1500),
        receiveTimeout: const Duration(milliseconds: 4200),
      ),
      null,
      null,
    );

    // Longest budget wins, rounded up to whole seconds.
    expect(fake.lastRequest?['timeoutSeconds'], 5);
  });

  test('core timeouts map onto dio timeout types', () async {
    fake.failWith = const VaneHttpException(
      'HTTP/3 request timed out',
      kind: VaneErrorKind.timeout,
    );
    await expectLater(
      adapter.fetch(
        RequestOptions(path: 'https://example.com/thing'),
        null,
        null,
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );

    fake.failWith = const VaneHttpException(
      'HTTP/3 handshake timed out',
      kind: VaneErrorKind.connectTimeout,
    );
    await expectLater(
      adapter.fetch(
        RequestOptions(path: 'https://example.com/thing'),
        null,
        null,
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.connectionTimeout,
        ),
      ),
    );
  });

  test('other core failures map onto connectionError', () async {
    fake.failWith = const VaneHttpException(
      'QUIC error: TlsFail',
      kind: VaneErrorKind.transport,
    );
    await expectLater(
      adapter.fetch(
        RequestOptions(path: 'https://example.com/thing'),
        null,
        null,
      ),
      throwsA(
        isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.connectionError)
            .having((e) => e.message, 'message', contains('QUIC error'))
            .having((e) => e.error, 'error', isA<VaneHttpException>()),
      ),
    );
  });

  test('every error kind maps onto a dio exception type', () async {
    // The whole point of the kind: no branch here reads the message, so the
    // core is free to reword an error without breaking a dio caller.
    const expected = <VaneErrorKind, DioExceptionType>{
      VaneErrorKind.connectTimeout: DioExceptionType.connectionTimeout,
      VaneErrorKind.timeout: DioExceptionType.receiveTimeout,
      VaneErrorKind.tls: DioExceptionType.badCertificate,
      VaneErrorKind.cancelled: DioExceptionType.cancel,
      VaneErrorKind.invalidRequest: DioExceptionType.unknown,
      VaneErrorKind.bodyLimitExceeded: DioExceptionType.unknown,
      VaneErrorKind.protocolUnsupported: DioExceptionType.unknown,
      VaneErrorKind.transport: DioExceptionType.connectionError,
      VaneErrorKind.unknown: DioExceptionType.connectionError,
    };
    expect(expected.keys, containsAll(VaneErrorKind.values));

    for (final entry in expected.entries) {
      // Deliberately misleading text: only the kind may decide the type.
      fake.failWith = VaneHttpException('handshake timed out', kind: entry.key);
      await expectLater(
        adapter.fetch(
          RequestOptions(path: 'https://example.com/thing'),
          null,
          null,
        ),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            '${entry.key}',
            entry.value,
          ),
        ),
      );
    }
  });

  test('a cancel during body collection never reaches the core', () async {
    await expectLater(
      adapter.fetch(
        RequestOptions(path: 'https://example.com/thing', method: 'POST'),
        Stream<Uint8List>.fromIterable(<Uint8List>[Uint8List(1)]),
        Future<void>.value(),
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(fake.lastRequest, isNull);
    // The adapter refuses before `execute`, so nothing is registered to cancel.
    expect(fake.cancelledTokens, isEmpty);
  });

  test('cancelling in flight surfaces as DioExceptionType.cancel', () async {
    final gate = Completer<void>();
    final cancel = Completer<void>();
    fake
      ..gate = gate
      ..failWith = const VaneHttpException('Vane request was cancelled');

    final pending = adapter.fetch(
      RequestOptions(path: 'https://example.com/thing'),
      null,
      cancel.future,
    );
    await Future<void>.delayed(Duration.zero);
    cancel.complete();
    await Future<void>.delayed(Duration.zero);
    gate.complete();

    await expectLater(
      pending,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(fake.lastRequest?['cancelTokenId'], isNotNull);
  });

  test('close is idempotent and rejects later requests', () async {
    await adapter.fetch(
      RequestOptions(path: 'https://example.com/thing'),
      null,
      null,
    );

    adapter
      ..close()
      ..close(force: true);

    await expectLater(
      adapter.fetch(
        RequestOptions(path: 'https://example.com/thing'),
        null,
        null,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'closing mid-fetch fails the request instead of reopening a client',
    () async {
      final chunks = StreamController<Uint8List>();
      final pending = adapter.fetch(
        RequestOptions(path: 'https://example.com/thing', method: 'POST'),
        chunks.stream,
        null,
      );

      // fetch() is parked collecting the body; close lands in that window.
      await Future<void>.delayed(Duration.zero);
      adapter.close();
      chunks.add(Uint8List(1));
      await chunks.close();

      await expectLater(pending, throwsA(isA<StateError>()));
    },
  );

  test(
    'an injected client outlives the adapter, an owned one does not',
    () async {
      await adapter.fetch(
        RequestOptions(path: 'https://example.com/thing'),
        null,
        null,
      );
      adapter.close();
      await Future<void>.delayed(Duration.zero);
      expect(fake.closedClients, 0, reason: 'injected client must stay open');

      final previous = VaneFlutterPlatform.instance;
      addTearDown(() => VaneFlutterPlatform.instance = previous);
      VaneFlutterPlatform.instance = fake;
      final owned = VaneDioAdapter();
      await owned.fetch(
        RequestOptions(path: 'https://example.com/thing'),
        null,
        null,
      );
      owned.close();
      await Future<void>.delayed(Duration.zero);
      expect(fake.closedClients, 1, reason: 'owned client must be closed');

      await vane.close();
    },
  );

  test('a Dio instance round-trips a response through the adapter', () async {
    final dio = Dio()..httpClientAdapter = adapter;

    final response = await dio.get<String>('https://example.com/thing');

    expect(response.statusCode, 201);
    expect(response.data, 'hello');
    expect(response.headers.value('content-type'), 'text/plain');
    expect(response.statusMessage, isNull);
  });

  test(
    'a non-2xx status stays dio badResponse, not an adapter error',
    () async {
      fake.response = VaneResponse(
        statusCode: 404,
        headers: const <(String, String)>[],
        body: Uint8List(0),
        isSuccess: false,
        url: 'https://example.com/thing',
      );
      final dio = Dio()..httpClientAdapter = adapter;

      await expectLater(
        dio.get<String>('https://example.com/thing'),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.badResponse)
              .having((e) => e.response?.statusCode, 'statusCode', 404),
        ),
      );
    },
  );
}
