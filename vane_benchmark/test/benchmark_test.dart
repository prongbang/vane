// Cross-client × protocol latency matrix: vane (FFI), vane via the dio
// adapter, and rhttp each pinned to HTTP/1.1, HTTP/2 and HTTP/3; dio's
// dart:io adapter (h1.1) and dio_http2_adapter (h2); package:http (h1.1) —
// all in one process, against one endpoint, sequentially, so every
// comparison is like-for-like at the same protocol.
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
// - Row names state the pinned config; the proto column is what each
//   response actually reported — except package:http, whose API cannot say
//   (dart:io speaks only HTTP/1.1; marked "stated"). A row that negotiates
//   something other than its pin gets a NOTE line, and a pinned cell that
//   cannot reach its protocol is reported as an ERROR row, never silently
//   downgraded (dio's Http2Adapter would otherwise fall back to dart:io
//   h1.1; that fallback is disabled here).
// - Cells that cannot exist (dio h3, package:http h2/h3) are printed as
//   "unsupported" — that a client covers a column at all is a result.
// - Connection pooling / keep-alive is left ON for every client (each one's
//   default), because that is how all of them ship.

import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
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
  _Contender(
    this.name,
    this.group, {
    required this.fire,
    this.protoStated = false,
  });

  /// Unique display name; states the pinned config (e.g. `vane (ffi, h2)`).
  final String name;

  /// Protocol group this row is pinned to: the table it belongs in.
  final String group;

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
/// forwards dart:io's `protocolVersion`, Http2Adapter stamps `'2.0'`, the
/// Vane adapter maps the core's enum onto the same scheme (`'3.0'` for h3).
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

const List<String> _groups = <String>['HTTP/1.1', 'HTTP/2', 'HTTP/3'];

/// Cells that cannot exist, printed per group so their absence is a stated
/// result rather than a silently missing row.
const List<(String group, String name, String reason)> _unsupported = [
  (
    'HTTP/2',
    'dio (dart:io)',
    'dart:io has no HTTP/2 — the dio (http2 adapter) row is a separate '
        'first-party package',
  ),
  ('HTTP/2', 'package:http', 'dart:io HttpClient speaks HTTP/1.1 only'),
  ('HTTP/3', 'dio', 'no HTTP/3 adapter exists for dio'),
  ('HTTP/3', 'package:http', 'dart:io HttpClient speaks HTTP/1.1 only'),
];

void main() {
  test('cross-client × protocol latency matrix', () async {
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
        'run `cargo build --release` in vane-rs; the default features '
        'include the tcp-fallback the h1/h2 rows need)',
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
    // are shared, while each VaneClient below still owns its native client
    // and connection pool, pinned to one protocol.
    final ffiPlatform = FfiVaneFlutter(library: DynamicLibrary.open(vaneLib));
    VaneClient vaneAt(VaneProtocolMode mode) => VaneClient(
      configuration: VaneConfiguration(protocolMode: mode),
      platform: ffiPlatform,
    );
    const vaneModes = <(String group, String pin, VaneProtocolMode mode)>[
      ('HTTP/1.1', 'h1', VaneProtocolMode.http1Only),
      ('HTTP/2', 'h2', VaneProtocolMode.http2Only),
      ('HTTP/3', 'h3', VaneProtocolMode.http3Only),
    ];
    final vaneClients = <String, VaneClient>{
      for (final (_, pin, mode) in vaneModes) pin: vaneAt(mode),
    };
    final vaneDioClients = <String, VaneClient>{
      for (final (_, pin, mode) in vaneModes) pin: vaneAt(mode),
    };
    Dio dioWith([HttpClientAdapter? adapter]) {
      final dio = Dio(
        BaseOptions(
          responseType: ResponseType.bytes,
          // Status handling is the harness's job, uniformly across clients.
          validateStatus: (_) => true,
        ),
      );
      if (adapter != null) {
        dio.httpClientAdapter = adapter;
      }
      return dio;
    }

    final vaneDios = <String, Dio>{
      for (final entry in vaneDioClients.entries)
        entry.key: dioWith(VaneDioAdapter(client: entry.value)),
    };
    final ioDio = dioWith(); // dio's stock dart:io adapter
    final h2Dio = dioWith(
      Http2Adapter(
        ConnectionManager(),
        // A pinned h2 cell must fail loudly, not silently downgrade: the
        // adapter's default fallback would swap in dart:io HTTP/1.1 when the
        // server does not ALPN h2.
        onNotSupported: (options, requestStream, cancelFuture, e) => throw e,
      ),
    );
    final httpClient = http.Client();

    final rhttpClients = <String, rhttp.RhttpClient>{};
    if (rhttpLib != null) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(rhttpLib),
        // Same flag Rhttp.init() passes.
        forceSameCodegenVersion: false,
      );
      // rhttp's prefs map onto reqwest exactly as vane's modes do on its own
      // TCP/QUIC paths: http1_1 → http1_only(), http2 →
      // http2_prior_knowledge(), http3 → http3_prior_knowledge() — the
      // symmetric like-for-like head-to-heads.
      const rhttpPrefs = <(String pin, rhttp.HttpVersionPref pref)>[
        ('h1.1', rhttp.HttpVersionPref.http1_1),
        ('h2', rhttp.HttpVersionPref.http2),
        ('h3', rhttp.HttpVersionPref.http3),
      ];
      for (final (pin, pref) in rhttpPrefs) {
        rhttpClients[pin] = await rhttp.RhttpClient.create(
          settings: rhttp.ClientSettings(
            httpVersionPref: pref,
            throwOnStatusCode: false,
          ),
        );
      }
    }

    Future<_Shot> dioShot(Dio dio, Uri url) async {
      final r = await dio.getUri<List<int>>(url);
      return (
        status: r.statusCode ?? 0,
        bytes: r.data?.length ?? 0,
        proto: _dioProto(r.extra[HttpClientAdapter.extraKeyHttpVersion]),
      );
    }

    final contenders = <_Contender>[
      // Grouped construction order = grouped tables read in run order; the
      // per-round rotation below undoes any ordering advantage.
      for (final (group, pin, _) in vaneModes) ...[
        _Contender(
          'vane (ffi, $pin)',
          group,
          fire: (url) async {
            final r = await vaneClients[pin]!.get(url.toString());
            return (
              status: r.statusCode,
              bytes: r.body.length,
              proto: _vaneProto(r.httpVersion),
            );
          },
        ),
        _Contender(
          'vane (dio, $pin)',
          group,
          fire: (url) => dioShot(vaneDios[pin]!, url),
        ),
      ],
      if (rhttpClients.isNotEmpty)
        for (final entry in rhttpClients.entries)
          _Contender(
            'rhttp (${entry.key})',
            entry.key == 'h1.1'
                ? 'HTTP/1.1'
                : entry.key == 'h2'
                ? 'HTTP/2'
                : 'HTTP/3',
            fire: (url) async {
              final r = await entry.value.getBytes(url.toString());
              return (
                status: r.statusCode,
                bytes: r.body.length,
                proto: _rhttpProto(r.version),
              );
            },
          ),
      _Contender(
        'dio (dart:io)',
        'HTTP/1.1',
        fire: (url) => dioShot(ioDio, url),
      ),
      _Contender(
        'dio (http2 adapter)',
        'HTTP/2',
        fire: (url) => dioShot(h2Dio, url),
      ),
      _Contender(
        'package:http',
        'HTTP/1.1',
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
      for (final dio in vaneDios.values) {
        dio.close();
      }
      ioDio.close();
      h2Dio.close();
      httpClient.close();
      for (final client in rhttpClients.values) {
        client.dispose();
      }
      for (final client in vaneClients.values) {
        await client.close();
      }
      for (final client in vaneDioClients.values) {
        await client.close();
      }
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

    final header = _row('client', <String>[
      'proto',
      'cold_ms',
      'p50_ms',
      'p95_ms',
      'min_ms',
      'max_ms',
      'n',
      'bytes',
    ]);

    void printMeasured(_Contender c) {
      final pooled = c.pooled;
      if (pooled.isEmpty) {
        print(_row(c.name, const <String>[])); // name line, then the error
        print('  ERROR ${c.failure}');
        return;
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
      if (!c.protoStated &&
          (c.protocols.length != 1 || c.protocols.single != c.group)) {
        print(
          '  NOTE: negotiated ${c.protocols.join('+')}, '
          'not the pinned ${c.group}',
        );
      }
    }

    // Primary view — one table per protocol, so the like-for-like comparison
    // is the first thing a reader sees. Unsupported cells are stated.
    for (final group in _groups) {
      print('');
      print('== $group ==');
      print(header);
      contenders.where((c) => c.group == group).forEach(printMeasured);
      for (final (_, name, reason) in _unsupported.where(
        (u) => u.$1 == group,
      )) {
        print('${name.padRight(22)}   unsupported: $reason');
      }
    }

    // Secondary view — every measured row in one table, for cross-protocol
    // reading within a client.
    print('');
    print('== all rows ==');
    print(header);
    contenders.forEach(printMeasured);

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

    // The benchmark exists to measure Vane; a run where any Vane cell failed
    // must be loud, not a quietly shorter table. A tcp-fallback-less dylib
    // or an endpoint missing a protocol both land here.
    for (final c in contenders.where((c) => c.name.startsWith('vane'))) {
      expect(
        c.failure,
        isNull,
        reason:
            '${c.name} failed — does $base serve ${c.group}, and was '
            'libvane built with default features (tcp-fallback)?',
      );
      expect(c.pooled, hasLength(roundCount * perRound));
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
