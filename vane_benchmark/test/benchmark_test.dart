// Cross-client latency benchmark: vane (FFI), vane via the dio adapter,
// rhttp (pinned to h3 and at its default), dio's own dart:io adapter, and
// package:http — all in one process, against one endpoint, sequentially.
//
//   VANE_TEST_BASE_URL=https://cloudflare-quic.com \
//     flutter test test/benchmark_test.dart
//
// Env knobs (all optional): VANE_BENCH_ROUNDS (default 3),
// VANE_BENCH_REQUESTS per round (default 10), VANE_BENCH_WARMUP (default 5),
// VANE_TEST_LIBRARY / RHTTP_TEST_LIBRARY to point at specific dylibs.
//
// Methodology (full caveats in README.md):
// - Per client: 1 cold request (reported alone), then warmup requests
//   (discarded), then rounds × requests measured requests. p50/p95 are
//   nearest-rank over the pooled measured samples, matching
//   vane-rs/examples/bench.rs.
// - The visiting order rotates by one each round so no client systematically
//   rides a warmer network than the others.
// - The protocol column is what each response actually reported, except
//   package:http, whose API cannot say — dart:io speaks only HTTP/1.1 and the
//   row is marked "stated".
// - Connection pooling / keep-alive is left ON for every client (each one's
//   default), because that is how all of them ship.

import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart' as rhttp;
// ignore: implementation_imports -- Rhttp.init() only knows how to load the
// library cargokit bundles into a built Flutter app. On the host test VM the
// generated RustLib.init is the sole way to hand it a cargo-built dylib.
import 'package:rhttp/src/rust/frb_generated.dart' show RustLib;
import 'package:vane_flutter/vane_flutter.dart';
import 'package:vane_flutter/vane_flutter_ffi.dart';
import 'package:vane_flutter_dio/vane_flutter_dio.dart';

/// One request's outcome; the surrounding stopwatch does the timing.
typedef _Shot = ({int status, int bytes, String proto});

class _Contender {
  _Contender(this.name, {required this.fire, this.protoStated = false});

  final String name;
  final Future<_Shot> Function(Uri url) fire;

  /// True when the protocol label is asserted from documentation rather than
  /// read off the response (package:http exposes no version).
  final bool protoStated;

  Duration? cold;
  final List<List<Duration>> rounds = <List<Duration>>[];
  final Set<String> protocols = <String>{};
  int? bodyBytes;
  Object? failure;

  List<Duration> get pooled => <Duration>[
    for (final round in rounds) ...round,
  ]..sort();
}

int _envInt(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

/// Same resolution shape as vane_flutter's FFI tests, widened with the
/// CARGO_TARGET_DIR convention scripts/release-build.sh sets up.
String? _findLibrary(String stem, {required String override}) {
  final overridePath = Platform.environment[override];
  if (overridePath != null) {
    return File(overridePath).existsSync() ? overridePath : null;
  }
  final extension = Platform.isMacOS ? 'dylib' : 'so';
  final home = Platform.environment['HOME'];
  final cargoTarget = Platform.environment['CARGO_TARGET_DIR'];
  for (final candidate in <String>[
    if (cargoTarget != null) '$cargoTarget/release/lib$stem.$extension',
    if (home != null) '$home/.cargo-target/release/lib$stem.$extension',
    '../vane-rs/target/release/lib$stem.$extension',
    '../vane-rs/target/debug/lib$stem.$extension',
  ]) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}

String _vaneProto(VaneHttpVersion? version) => switch (version) {
  VaneHttpVersion.http10 => 'HTTP/1.0',
  VaneHttpVersion.http11 => 'HTTP/1.1',
  VaneHttpVersion.http2 => 'HTTP/2',
  VaneHttpVersion.http3 => 'HTTP/3',
  null => 'unknown',
};

/// dio's `extraKeyHttpVersion` carries `'1.1'`-style strings: the IO adapter
/// forwards dart:io's `protocolVersion`, the Vane adapter maps the core's
/// enum onto the same scheme (`'3.0'` for h3).
String _dioProto(Object? version) => switch (version) {
  '1.0' => 'HTTP/1.0',
  '1.1' => 'HTTP/1.1',
  '2.0' => 'HTTP/2',
  '3.0' => 'HTTP/3',
  final String other => 'HTTP/$other',
  _ => 'unknown',
};

String _rhttpProto(rhttp.HttpVersion version) => switch (version) {
  rhttp.HttpVersion.http09 => 'HTTP/0.9',
  rhttp.HttpVersion.http1_0 => 'HTTP/1.0',
  rhttp.HttpVersion.http1_1 => 'HTTP/1.1',
  rhttp.HttpVersion.http2 => 'HTTP/2',
  rhttp.HttpVersion.http3 => 'HTTP/3',
  rhttp.HttpVersion.other => 'unknown',
};

/// Nearest-rank percentile over a sorted list — the exact formula
/// vane-rs/examples/bench.rs uses, so the numbers are comparable.
Duration _percentile(List<Duration> sorted, double pct) {
  if (sorted.isEmpty) {
    return Duration.zero;
  }
  final rank = ((pct / 100.0) * (sorted.length - 1)).round();
  return sorted[rank.clamp(0, sorted.length - 1)];
}

String _ms(Duration? d) =>
    d == null ? '-' : (d.inMicroseconds / 1000.0).toStringAsFixed(2);

String _row(String name, List<String> cells) =>
    name.padRight(22) + cells.map((cell) => cell.padLeft(9)).join();

void main() {
  test('cross-client latency benchmark', () async {
    final base = Platform.environment['VANE_TEST_BASE_URL'];
    if (base == null || !base.startsWith('https://')) {
      print('vane benchmark: skipped (VANE_TEST_BASE_URL not set to https)');
      return;
    }
    final url = Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}/');

    final vaneLib = _findLibrary('vane', override: 'VANE_TEST_LIBRARY');
    if (vaneLib == null) {
      print(
        'vane benchmark: skipped (libvane not built — '
        'run `cargo build --release` in vane-rs)',
      );
      return;
    }
    final rhttpLib = _findLibrary('rhttp', override: 'RHTTP_TEST_LIBRARY');

    final roundCount = _envInt('VANE_BENCH_ROUNDS', 3);
    final perRound = _envInt('VANE_BENCH_REQUESTS', 10);
    final warmup = _envInt('VANE_BENCH_WARMUP', 5);
    // Uniform per-request guard so one wedged client cannot stall the run.
    const guard = Duration(seconds: 30);

    // One shared FFI platform, like the production singleton: worker isolates
    // are shared, while each VaneClient below still owns its native client and
    // connection pool.
    final ffiPlatform = FfiVaneFlutter(library: DynamicLibrary.open(vaneLib));
    final vaneClient = VaneClient(platform: ffiPlatform);
    final vaneForDio = VaneClient(platform: ffiPlatform);
    final vaneDio = Dio(
      BaseOptions(
        responseType: ResponseType.bytes,
        // Status handling is the harness's job, uniformly across clients.
        validateStatus: (_) => true,
      ),
    )..httpClientAdapter = VaneDioAdapter(client: vaneForDio);
    final ioDio = Dio(
      BaseOptions(responseType: ResponseType.bytes, validateStatus: (_) => true),
    );
    final httpClient = http.Client();

    rhttp.RhttpClient? rhttpH3;
    rhttp.RhttpClient? rhttpDefault;
    if (rhttpLib != null) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(rhttpLib),
        // Same flag Rhttp.init() passes.
        forceSameCodegenVersion: false,
      );
      // Pinned to h3 (reqwest http3_prior_knowledge) — the symmetric
      // head-to-head with vane's http3Only default…
      rhttpH3 = await rhttp.RhttpClient.create(
        settings: const rhttp.ClientSettings(
          httpVersionPref: rhttp.HttpVersionPref.http3,
          throwOnStatusCode: false,
        ),
      );
      // …and untouched, negotiating whatever it prefers, because a default
      // config is what most rhttp users actually run.
      rhttpDefault = await rhttp.RhttpClient.create(
        settings: const rhttp.ClientSettings(throwOnStatusCode: false),
      );
    }

    final contenders = <_Contender>[
      _Contender(
        'vane (ffi)',
        fire: (url) async {
          final r = await vaneClient.get(url.toString());
          return (
            status: r.statusCode,
            bytes: r.body.length,
            proto: _vaneProto(r.httpVersion),
          );
        },
      ),
      _Contender(
        'vane (dio adapter)',
        fire: (url) async {
          final r = await vaneDio.getUri<List<int>>(url);
          return (
            status: r.statusCode ?? 0,
            bytes: r.data?.length ?? 0,
            proto: _dioProto(r.extra[HttpClientAdapter.extraKeyHttpVersion]),
          );
        },
      ),
      if (rhttpH3 != null)
        _Contender(
          'rhttp (h3)',
          fire: (url) async {
            final r = await rhttpH3!.getBytes(url.toString());
            return (
              status: r.statusCode,
              bytes: r.body.length,
              proto: _rhttpProto(r.version),
            );
          },
        ),
      if (rhttpDefault != null)
        _Contender(
          'rhttp (default)',
          fire: (url) async {
            final r = await rhttpDefault!.getBytes(url.toString());
            return (
              status: r.statusCode,
              bytes: r.body.length,
              proto: _rhttpProto(r.version),
            );
          },
        ),
      _Contender(
        'dio (dart:io)',
        fire: (url) async {
          final r = await ioDio.getUri<List<int>>(url);
          return (
            status: r.statusCode ?? 0,
            bytes: r.data?.length ?? 0,
            proto: _dioProto(r.extra[HttpClientAdapter.extraKeyHttpVersion]),
          );
        },
      ),
      _Contender(
        'package:http',
        protoStated: true,
        fire: (url) async {
          final r = await httpClient.get(url);
          return (
            status: r.statusCode,
            bytes: r.bodyBytes.length,
            // dart:io's HttpClient speaks only HTTP/1.1 and its API does not
            // report a version; stated, not observed.
            proto: 'HTTP/1.1',
          );
        },
      ),
    ];

    Future<Duration> timed(_Contender c) async {
      final stopwatch = Stopwatch()..start();
      final shot = await c.fire(url).timeout(guard);
      stopwatch.stop();
      if (shot.status != 200) {
        throw StateError('${c.name}: HTTP ${shot.status} from $url');
      }
      c.protocols.add(shot.proto);
      c.bodyBytes ??= shot.bytes;
      return stopwatch.elapsed;
    }

    try {
      // The first client to touch the host would otherwise pay the OS
      // resolver's cache miss inside its "cold" number while everyone after
      // it rides the warm cache. Resolve once up front so cold means
      // handshake, not resolver luck. (rhttp resolves in-process via reqwest,
      // so its cold still includes its own resolver's first lookup.)
      await InternetAddress.lookup(url.host);

      // Phase 1 — cold first request (fresh client, no pooled connection),
      // then discarded warmups: connection churn, JIT, isolate spin-up.
      for (final c in contenders) {
        try {
          c.cold = await timed(c);
          for (var i = 0; i < warmup; i++) {
            await timed(c);
          }
        } catch (error) {
          c.failure = error;
        }
      }

      // Phase 2 — measured rounds, visiting order rotated by one each round.
      for (var round = 0; round < roundCount; round++) {
        for (var i = 0; i < contenders.length; i++) {
          final c = contenders[(i + round) % contenders.length];
          if (c.failure != null) {
            continue;
          }
          final samples = <Duration>[];
          try {
            for (var k = 0; k < perRound; k++) {
              samples.add(await timed(c));
            }
          } catch (error) {
            c.failure = error;
          }
          c.rounds.add(samples);
        }
      }
    } finally {
      vaneDio.close();
      ioDio.close();
      httpClient.close();
      rhttpH3?.dispose();
      rhttpDefault?.dispose();
      await vaneClient.close();
      await vaneForDio.close();
      ffiPlatform.dispose();
      if (rhttpLib != null) {
        RustLib.dispose();
      }
    }

    // ---- Report ----
    print(
      'dart bench base_url=$base rounds=$roundCount '
      'requests_per_round=$perRound warmup=$warmup '
      'date=${DateTime.now().toIso8601String()}',
    );
    print(
      'host=${Platform.operatingSystem} ${Platform.operatingSystemVersion} '
      'dart=${Platform.version.split(' ').first}',
    );
    if (rhttpLib == null) {
      print(
        'rhttp: SKIPPED (librhttp not built — run tool/build_rhttp.sh first)',
      );
    }
    print('');
    print(
      _row('client', <String>[
        'proto',
        'cold_ms',
        'p50_ms',
        'p95_ms',
        'min_ms',
        'max_ms',
        'n',
        'bytes',
      ]),
    );
    for (final c in contenders) {
      final pooled = c.pooled;
      if (pooled.isEmpty) {
        print(_row(c.name, const <String>[])); // name line, then the error
        print('  ERROR ${c.failure}');
        continue;
      }
      final protoLabel =
          (c.protocols.toList()..sort()).join('+') +
          (c.protoStated ? '*' : '');
      print(
        _row(c.name, <String>[
          protoLabel,
          _ms(c.cold),
          _ms(_percentile(pooled, 50)),
          _ms(_percentile(pooled, 95)),
          _ms(pooled.first),
          _ms(pooled.last),
          '${pooled.length}',
          '${c.bodyBytes}',
        ]),
      );
      if (c.failure != null) {
        print('  PARTIAL: later requests failed with ${c.failure}');
      }
    }
    print('');
    print('per-round p50_ms (drift check):');
    for (final c in contenders.where((c) => c.rounds.isNotEmpty)) {
      final cells = <String>[
        for (var i = 0; i < c.rounds.length; i++)
          'r${i + 1}=${_ms(_percentile(c.rounds[i].toList()..sort(), 50))}',
      ];
      print('  ${c.name.padRight(22)}${cells.join('  ')}');
    }
    print('');
    print(
      '* stated, not observed: package:http exposes no protocol version; '
      'dart:io speaks only HTTP/1.1.',
    );
    print(
      'pooling/keep-alive: ON for every client (each one\'s default). '
      'One machine, one network, sequential requests — RTT-dominated, '
      'not a lab. See README.md.',
    );

    // The benchmark exists to measure Vane; a run where Vane itself failed
    // must be loud, not a quietly shorter table.
    final vane = contenders.first;
    expect(
      vane.failure,
      isNull,
      reason:
          'vane (ffi) failed — is $base HTTP/3-capable? '
          'vane\'s default protocolMode is http3Only.',
    );
    expect(vane.pooled, hasLength(roundCount * perRound));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
