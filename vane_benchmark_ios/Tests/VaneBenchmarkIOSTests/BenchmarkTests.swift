// Cross-client × protocol latency matrix on Apple platforms: vane
// (VaneSwift, Rust FFI) pinned to HTTP/1.1, HTTP/2 and HTTP/3; URLSession
// (the platform baseline); Alamofire (the de-facto wrapper, on URLSession) —
// one process, one endpoint, sequential GETs, grouped per protocol so every
// comparison is like-for-like. Methodology mirrors
// vane_benchmark/test/benchmark_test.dart; see README.md for the one-command
// runner and full caveats.
//
// Env knobs (TEST_RUNNER_-prefixed on the xcodebuild command line):
//   VANE_TEST_BASE_URL   required, https origin serving h1.1/h2/h3
//   VANE_BENCH_ROUNDS    default 3
//   VANE_BENCH_REQUESTS  per round, default 10
//   VANE_BENCH_WARMUP    default 5
//   VANE_BENCH_JSON      host path for the metrics file
//
// Protocol pinning, honestly:
// - vane pins with VaneProtocolMode (http1Only/http2Only/http3Only); the
//   proto column reads VaneResponse.httpVersion.
// - URLSession/Alamofire CANNOT pin. There is no public API to restrict
//   URLSession to HTTP/1.1 (ALPN always offers h2), so those HTTP/1.1 cells
//   are "unsupported". URLRequest.assumesHTTP3Capable is a hint that races
//   QUIC and silently falls back — not a pin. Their rows are labeled (alpn)
//   and (h3 hint); the proto column reads
//   URLSessionTaskMetrics.transactionMetrics.networkProtocolName, never an
//   assumption, and a row whose observed protocol differs from its group
//   prints a NOTE.
// - Pooling/keep-alive is ON for every client (each one's default).
//   Response caching is OFF for URLSession/Alamofire (ephemeral config, no
//   URLCache): vane has no response cache, and a cache would benchmark the
//   cache. The per-request guard is each client's 30 s request timeout —
//   vane's shipped default, mirrored onto the URLSession configs.

import Alamofire
import Darwin
import Foundation
import Testing
import VaneSwift

// MARK: - Plumbing

/// One request's outcome; the surrounding clock does the timing.
private struct Shot {
    let status: Int
    let bytes: Int
    let proto: String
}

private final class Contender {
    /// Unique display name; states the pin or its absence (e.g. `vane (h2)`,
    /// `urlsession (alpn)`).
    let name: String
    /// Protocol group this row belongs to: the table it is printed in.
    let group: String
    let fire: (URL) async throws -> Shot

    var cold: Double?
    var rounds: [[Double]] = []
    var protocols: Set<String> = []
    var bodyBytes: Int?
    var failure: String?

    init(_ name: String, _ group: String, fire: @escaping (URL) async throws -> Shot) {
        self.name = name
        self.group = group
        self.fire = fire
    }

    var pooled: [Double] { rounds.flatMap { $0 }.sorted() }
}

private struct BenchError: Error, CustomStringConvertible {
    let description: String
}

private func envString(_ name: String) -> String? {
    ProcessInfo.processInfo.environment[name]
}

private func envInt(_ name: String, _ fallback: Int) -> Int {
    envString(name).flatMap(Int.init) ?? fallback
}

/// Nearest-rank percentile over a sorted list — the exact formula
/// vane-rs/examples/bench.rs and the Dart harness use, so numbers compare.
private func percentile(_ sorted: [Double], _ pct: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let rank = Int((pct / 100.0 * Double(sorted.count - 1)).rounded())
    return sorted[min(max(rank, 0), sorted.count - 1)]
}

private func ms(_ value: Double?) -> String {
    value.map { String(format: "%.2f", $0) } ?? "-"
}

private func pad(_ text: String, right width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

private func pad(_ text: String, left width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

private func row(_ name: String, _ cells: [String]) -> String {
    pad(name, right: 22) + cells.map { pad($0, left: 9) }.joined()
}

private func vaneProto(_ version: VaneHttpVersion?) -> String {
    switch version {
    case .http10: return "HTTP/1.0"
    case .http11: return "HTTP/1.1"
    case .http2: return "HTTP/2"
    case .http3: return "HTTP/3"
    case nil: return "unknown"
    }
}

/// URLSessionTaskMetrics reports ALPN ids ("h2", "h3", "http/1.1").
private func alpnProto(_ name: String?) -> String {
    switch name {
    case "h3": return "HTTP/3"
    case "h2": return "HTTP/2"
    case "http/1.1": return "HTTP/1.1"
    case "http/1.0": return "HTTP/1.0"
    case let other?: return other
    case nil: return "unknown"
    }
}

/// Captures the negotiated protocol of one task. didFinishCollecting is
/// delivered on the session's serial delegate queue before the task
/// completes, so the value is set by the time the awaited call returns.
private final class MetricsCapture: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var protocolName: String?

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let name = metrics.transactionMetrics.last?.networkProtocolName
        lock.withLock { protocolName = name }
    }

    var negotiated: String? { lock.withLock { protocolName } }
}

private let groups = ["HTTP/1.1", "HTTP/2", "HTTP/3"]

/// Cells that cannot exist, printed per group so their absence is a stated
/// result rather than a silently missing row.
private let unsupportedCells: [(group: String, name: String, reason: String)] = [
    (
        "HTTP/1.1", "urlsession",
        "no public API restricts URLSession to HTTP/1.1 — ALPN always offers "
            + "h2 and URLSessionConfiguration has no HTTP version knob"
    ),
    (
        "HTTP/1.1", "alamofire",
        "sits on URLSession; the same HTTP/1.1 pin does not exist"
    ),
]

// MARK: - The benchmark

struct VaneBenchmarkIOSTests {
    @Test func crossClientProtocolLatencyMatrix() async throws {
        guard let base = envString("VANE_TEST_BASE_URL"), base.hasPrefix("https://") else {
            print("vane ios benchmark: skipped (VANE_TEST_BASE_URL not set to https)")
            return
        }
        let trimmedBase = base.replacingOccurrences(
            of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: trimmedBase + "/"), let host = url.host else {
            throw BenchError(description: "unparseable VANE_TEST_BASE_URL: \(base)")
        }

        let roundCount = envInt("VANE_BENCH_ROUNDS", 3)
        let perRound = envInt("VANE_BENCH_REQUESTS", 10)
        let warmup = envInt("VANE_BENCH_WARMUP", 5)

        // Each Vane client owns its native connection pool, pinned to one
        // protocol. Defaults are the shipped ones: pooling ON, 30 s timeout.
        func vaneClient(_ mode: VaneProtocolMode) throws -> VaneClient {
            var config = createDefaultConfig()
            config.protocolMode = mode
            return try createVaneClient(config: config)
        }
        let vaneClients: [(group: String, pin: String, client: VaneClient)] = [
            ("HTTP/1.1", "h1", try vaneClient(.http1Only)),
            ("HTTP/2", "h2", try vaneClient(.http2Only)),
            ("HTTP/3", "h3", try vaneClient(.http3Only)),
        ]

        // Ephemeral so no disk cache/cookies bleed between runs; no URLCache
        // because vane has no response cache; 30 s guard matching vane's
        // shipped default timeout. Pooling/keep-alive stays ON (the default).
        func sessionConfiguration() -> URLSessionConfiguration {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 30
            return config
        }
        // One session per row so each owns its connection pool, exactly as
        // each Vane client owns its native pool.
        let urlSessionAlpn = URLSession(configuration: sessionConfiguration())
        let urlSessionH3 = URLSession(configuration: sessionConfiguration())
        let alamofireAlpn = Session(configuration: sessionConfiguration())
        let alamofireH3 = Session(configuration: sessionConfiguration())

        func urlSessionShot(_ session: URLSession, _ url: URL, h3Hint: Bool) async throws -> Shot {
            var request = URLRequest(url: url)
            if h3Hint { request.assumesHTTP3Capable = true }
            let capture = MetricsCapture()
            let (data, response) = try await session.data(for: request, delegate: capture)
            return Shot(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                bytes: data.count,
                proto: alpnProto(capture.negotiated))
        }

        func alamofireShot(_ session: Session, _ url: URL, h3Hint: Bool) async throws -> Shot {
            let response = await session.request(url) { request in
                if h3Hint { request.assumesHTTP3Capable = true }
            }.serializingData().response
            let data = try response.result.get()
            return Shot(
                status: response.response?.statusCode ?? 0,
                bytes: data.count,
                proto: alpnProto(response.metrics?.transactionMetrics.last?.networkProtocolName))
        }

        // Grouped construction order = grouped tables read in run order; the
        // per-round rotation below undoes any ordering advantage. The (alpn)
        // rows run their cold phase before any (h3 hint) traffic so an
        // Alt-Svc-driven h3 upgrade cannot contaminate their cold numbers —
        // if it shows up later anyway, the observed proto column says so.
        let contenders: [Contender] = vaneClients.map { entry in
            Contender("vane (\(entry.pin))", entry.group) { url in
                let r = try await entry.client.get(url.absoluteString)
                return Shot(
                    status: Int(r.statusCode),
                    bytes: r.body.count,
                    proto: vaneProto(r.httpVersion))
            }
        } + [
            Contender("urlsession (alpn)", "HTTP/2") { url in
                try await urlSessionShot(urlSessionAlpn, url, h3Hint: false)
            },
            Contender("alamofire (alpn)", "HTTP/2") { url in
                try await alamofireShot(alamofireAlpn, url, h3Hint: false)
            },
            Contender("urlsession (h3 hint)", "HTTP/3") { url in
                try await urlSessionShot(urlSessionH3, url, h3Hint: true)
            },
            Contender("alamofire (h3 hint)", "HTTP/3") { url in
                try await alamofireShot(alamofireH3, url, h3Hint: true)
            },
        ]

        func timed(_ c: Contender) async throws -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            let shot = try await c.fire(url)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            guard shot.status == 200 else {
                throw BenchError(description: "\(c.name): HTTP \(shot.status) from \(url)")
            }
            c.protocols.insert(shot.proto)
            if c.bodyBytes == nil { c.bodyBytes = shot.bytes }
            return elapsed
        }

        // The first client to touch the host would otherwise pay the OS
        // resolver's cache miss inside its cold number. Resolve once up
        // front so cold means handshake, not resolver luck. (vane resolves
        // through its own path; its cold still includes its first lookup.)
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var resolved: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, "443", &hints, &resolved) == 0, let resolved {
            freeaddrinfo(resolved)
        }

        // Phase 1 — cold first request (fresh client, no pooled connection),
        // then discarded warmups.
        for c in contenders {
            do {
                c.cold = try await timed(c)
                for _ in 0..<warmup { _ = try await timed(c) }
            } catch {
                c.failure = String(describing: error)
            }
        }

        // Phase 2 — measured rounds, visiting order rotated by one each
        // round so no client systematically rides a warmer network.
        for round in 0..<roundCount {
            for i in 0..<contenders.count {
                let c = contenders[(i + round) % contenders.count]
                if c.failure != nil { continue }
                var samples: [Double] = []
                do {
                    for _ in 0..<perRound { samples.append(try await timed(c)) }
                } catch {
                    c.failure = String(describing: error)
                }
                c.rounds.append(samples)
            }
        }

        urlSessionAlpn.finishTasksAndInvalidate()
        urlSessionH3.finishTasksAndInvalidate()

        // ---- Report ----
        let deviceName = envString("SIMULATOR_DEVICE_NAME") ?? "unknown-device"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let hostLabel = "ios-simulator \(deviceName) \(osVersion)"
        let isoDate = ISO8601DateFormatter().string(from: Date())

        print(
            "ios bench base_url=\(trimmedBase) rounds=\(roundCount) "
                + "requests_per_round=\(perRound) warmup=\(warmup) date=\(isoDate)")
        print("host=\(hostLabel)")
        print("SIMULATOR RUN: these numbers use the Mac host's network stack, not an iPhone's.")

        let header = row(
            "client",
            ["proto", "cold_ms", "p50_ms", "p95_ms", "min_ms", "max_ms", "n", "bytes"])

        func printMeasured(_ c: Contender) {
            let pooled = c.pooled
            if pooled.isEmpty {
                print(row(c.name, []))
                print("  ERROR \(c.failure ?? "no samples")")
                return
            }
            let protoLabel = c.protocols.sorted().joined(separator: "+")
            print(
                row(
                    c.name,
                    [
                        protoLabel, ms(c.cold), ms(percentile(pooled, 50)),
                        ms(percentile(pooled, 95)), ms(pooled.first), ms(pooled.last),
                        "\(pooled.count)", "\(c.bodyBytes ?? 0)",
                    ]))
            if c.failure != nil {
                print("  PARTIAL: later requests failed with \(c.failure!)")
            }
            if c.protocols != [c.group] {
                print(
                    "  NOTE: negotiated \(protoLabel), not this row's protocol "
                        + "group \(c.group)")
            }
        }

        // Primary view — one table per protocol, so the like-for-like
        // comparison is the first thing a reader sees.
        for group in groups {
            print("")
            print("== \(group) ==")
            print(header)
            for c in contenders where c.group == group { printMeasured(c) }
            for cell in unsupportedCells where cell.group == group {
                print("\(pad(cell.name, right: 22))   unsupported: \(cell.reason)")
            }
        }

        // Secondary view — every measured row in one table.
        print("")
        print("== all rows ==")
        print(header)
        contenders.forEach(printMeasured)

        print("")
        print("per-round p50_ms (drift check):")
        for c in contenders where !c.rounds.isEmpty {
            let cells = c.rounds.enumerated().map { index, round in
                "r\(index + 1)=\(ms(percentile(round.sorted(), 50)))"
            }
            print("  \(pad(c.name, right: 22))\(cells.joined(separator: "  "))")
        }
        print("")
        print(
            "urlsession/alamofire rows are ALPN-negotiated or Alt-Svc/QUIC-raced, "
                + "never pinned — the proto column is what URLSessionTaskMetrics "
                + "reported. pooling/keep-alive: ON for every client (each one's "
                + "default); response caching OFF. One machine, one network, "
                + "sequential requests — RTT-dominated, not a lab.")

        // Machine-readable twin, same schema as the Dart harness plus
        // platform:"ios". Written before the assertions so a failed Vane cell
        // still leaves evidence.
        func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        let rows: [[String: Any]] = contenders.map { c in
            let pooled = c.pooled
            return [
                "client": c.name,
                "pinned_protocol": c.group,
                "observed_protocol": c.protocols.sorted().joined(separator: "+"),
                "protocol_stated_not_observed": false,
                "cold_ms": c.cold.map(round3) as Any? ?? NSNull(),
                "p50_ms": pooled.isEmpty ? NSNull() : round3(percentile(pooled, 50)),
                "p95_ms": pooled.isEmpty ? NSNull() : round3(percentile(pooled, 95)),
                "min_ms": pooled.isEmpty ? NSNull() : round3(pooled.first!),
                "max_ms": pooled.isEmpty ? NSNull() : round3(pooled.last!),
                "n": pooled.count,
                "body_bytes": c.bodyBytes as Any? ?? NSNull(),
                "round_p50_ms": c.rounds.map { round3(percentile($0.sorted(), 50)) },
                "failure": c.failure as Any? ?? NSNull(),
            ]
        }
        let metrics: [String: Any] = [
            "schema": 1,
            "platform": "ios",
            "date": isoDate,
            "base_url": trimmedBase,
            "host": hostLabel,
            "rounds": roundCount,
            "requests_per_round": perRound,
            "warmup": warmup,
            "rows": rows,
            "unsupported": unsupportedCells.map {
                ["protocol": $0.group, "client": $0.name, "reason": $0.reason]
            },
        ]
        let jsonData = try JSONSerialization.data(
            withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        let jsonText = String(decoding: jsonData, as: UTF8.self)

        // Fallback capture path: the JSON always lands in the log, markers
        // make it extractable even if the host-path write cannot happen.
        print("")
        print("=== VANE_BENCH_JSON_BEGIN ===")
        print(jsonText)
        print("=== VANE_BENCH_JSON_END ===")

        // Simulator tests run against the host filesystem, so an absolute
        // host path (TEST_RUNNER_VANE_BENCH_JSON) is writable directly.
        if let jsonPath = envString("VANE_BENCH_JSON"), !jsonPath.isEmpty {
            let fileURL = URL(fileURLWithPath: jsonPath)
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try (jsonText + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
                print("metrics written to \(jsonPath)")
            } catch {
                print("metrics file write FAILED (\(error)) — capture the JSON block above")
            }
        }

        // The benchmark exists to measure Vane; a run where any Vane cell
        // failed must be loud, not a quietly shorter table.
        for c in contenders where c.name.hasPrefix("vane") {
            #expect(
                c.failure == nil,
                "\(c.name) failed (\(c.failure ?? "")) — does \(trimmedBase) serve \(c.group), and does the XCFramework carry tcp-fallback?"
            )
            #expect(c.pooled.count == roundCount * perRound)
        }
    }
}
