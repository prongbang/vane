import Flutter
import UIKit

#if canImport(VaneSwift)
import VaneSwift
#endif

public class VaneFlutterPlugin: NSObject, FlutterPlugin {
  private var nextHandle: Int64 = 1
  private var clients: [Int64: VaneClient] = [:]
  private let lock = NSLock()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "vane_flutter", binaryMessenger: registrar.messenger())
    let instance = VaneFlutterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "createClient":
      createClient(call, result: result)
    case "execute":
      execute(call, result: result)
    case "closeClient":
      closeClient(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func createClient(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      let args = try requiredDictionary(call.arguments)
      let config = try configFromMap(try requiredDictionary(args["configuration"]))
      let client = try createVaneClient(config: config)
      lock.lock()
      let handle = nextHandle
      nextHandle += 1
      clients[handle] = client
      lock.unlock()
      result(handle)
    } catch {
      result(FlutterError(code: "VANE_CREATE_CLIENT", message: "\(error)", details: nil))
    }
  }

  private func execute(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      let args = try requiredDictionary(call.arguments)
      let handle = try requiredInt64(args["handle"])
      let request = try requestFromMap(try requiredDictionary(args["request"]))
      guard let client = client(for: handle) else {
        result(FlutterError(code: "VANE_INVALID_CLIENT", message: "No Vane client exists for handle \(handle)", details: nil))
        return
      }

      Task {
        do {
          let response = try await client.execute(request)
          result(response.toMap())
        } catch {
          result(FlutterError(code: "VANE_EXECUTE", message: "\(error)", details: nil))
        }
      }
    } catch {
      result(FlutterError(code: "VANE_EXECUTE", message: "\(error)", details: nil))
    }
  }

  private func closeClient(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      let args = try requiredDictionary(call.arguments)
      let handle = try requiredInt64(args["handle"])
      lock.lock()
      clients.removeValue(forKey: handle)
      lock.unlock()
      result(nil)
    } catch {
      result(FlutterError(code: "VANE_CLOSE_CLIENT", message: "\(error)", details: nil))
    }
  }

  private func client(for handle: Int64) -> VaneClient? {
    lock.lock()
    defer { lock.unlock() }
    return clients[handle]
  }

  private func configFromMap(_ map: [String: Any]) throws -> VaneClientConfig {
    var config = createDefaultConfig()
    config.baseUrl = map["baseUrl"] as? String
    config.defaultHeaders = stringMap(map["defaultHeaders"])
    config.dnsOverrides = stringMap(map["dnsOverrides"])
    config.certificatePins = stringListMap(map["certificatePins"])
    config.cookiesEnabled = boolValue(map["cookiesEnabled"], fallback: config.cookiesEnabled)
    config.connectionPoolEnabled = boolValue(map["connectionPoolEnabled"], fallback: config.connectionPoolEnabled)
    config.maxIdleConnections = uint64Value(map["maxIdleConnections"], fallback: config.maxIdleConnections)
    config.connectionIdleTimeoutSeconds = uint64Value(
      map["connectionIdleTimeoutSeconds"],
      fallback: config.connectionIdleTimeoutSeconds
    )
    config.retryMaxAttempts = uint64Value(map["retryMaxAttempts"], fallback: config.retryMaxAttempts)
    config.retryInitialDelayMillis = uint64Value(
      map["retryInitialDelayMillis"],
      fallback: config.retryInitialDelayMillis
    )
    config.retryMaxDelayMillis = uint64Value(map["retryMaxDelayMillis"], fallback: config.retryMaxDelayMillis)
    config.retryUnsafeMethods = boolValue(map["retryUnsafeMethods"], fallback: config.retryUnsafeMethods)
    config.maxRequestBodyBytes = uint64Value(map["maxRequestBodyBytes"], fallback: config.maxRequestBodyBytes)
    config.maxResponseBodyBytes = uint64Value(map["maxResponseBodyBytes"], fallback: config.maxResponseBodyBytes)
    config.timeoutSeconds = optionalUInt64Value(map["timeoutSeconds"])
    config.followRedirects = boolValue(map["followRedirects"], fallback: config.followRedirects)
    config.userAgent = map["userAgent"] as? String
    config.protocolMode = protocolMode(map["protocolMode"] as? String)
    config.proxyUrl = map["proxyUrl"] as? String
    config.proxyAuthorization = map["proxyAuthorization"] as? String
    return config
  }

  private func requestFromMap(_ map: [String: Any]) throws -> VaneRequest {
    return VaneRequest(
      url: try requiredString(map["url"]),
      method: map["method"] as? String ?? "GET",
      headers: stringMap(map["headers"]),
      queryParams: stringMap(map["queryParams"]),
      body: map["body"] as? FlutterStandardTypedData != nil
        ? (map["body"] as! FlutterStandardTypedData).data
        : map["body"] as? Data,
      timeoutSeconds: optionalUInt64Value(map["timeoutSeconds"]),
      followRedirects: boolValue(map["followRedirects"], fallback: true)
    )
  }

  private func protocolMode(_ value: String?) -> VaneProtocolMode {
    switch value {
    case "http3ThenHttp2ThenHttp1":
      return .http3ThenHttp2ThenHttp1
    case "http2ThenHttp1":
      return .http2ThenHttp1
    case "http2Only":
      return .http2Only
    case "http1Only":
      return .http1Only
    default:
      return .http3Only
    }
  }

  private func stringMap(_ value: Any?) -> [String: String] {
    guard let map = value as? [String: Any] else {
      return [:]
    }
    return map.reduce(into: [String: String]()) { result, entry in
      result[entry.key] = "\(entry.value)"
    }
  }

  private func stringListMap(_ value: Any?) -> [String: [String]] {
    guard let map = value as? [String: Any] else {
      return [:]
    }
    return map.reduce(into: [String: [String]]()) { result, entry in
      result[entry.key] = (entry.value as? [Any])?.map { "\($0)" } ?? []
    }
  }

  private func boolValue(_ value: Any?, fallback: Bool) -> Bool {
    return value as? Bool ?? fallback
  }

  private func uint64Value(_ value: Any?, fallback: UInt64) -> UInt64 {
    guard let number = value as? NSNumber else {
      return fallback
    }
    return number.uint64Value
  }

  private func optionalUInt64Value(_ value: Any?) -> UInt64? {
    return (value as? NSNumber)?.uint64Value
  }

  private func requiredDictionary(_ value: Any?) throws -> [String: Any] {
    guard let dictionary = value as? [String: Any] else {
      throw VaneFlutterError.invalidArguments
    }
    return dictionary
  }

  private func requiredString(_ value: Any?) throws -> String {
    guard let string = value as? String else {
      throw VaneFlutterError.invalidArguments
    }
    return string
  }

  private func requiredInt64(_ value: Any?) throws -> Int64 {
    guard let number = value as? NSNumber else {
      throw VaneFlutterError.invalidArguments
    }
    return number.int64Value
  }
}

private enum VaneFlutterError: Error {
  case invalidArguments
}

private extension VaneResponse {
  func toMap() -> [String: Any] {
    return [
      "statusCode": Int(statusCode),
      "headers": headers,
      "body": FlutterStandardTypedData(bytes: body),
      "isSuccess": isSuccess,
      "url": url
    ]
  }
}
