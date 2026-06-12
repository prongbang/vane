// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'vane_flutter_platform_interface.dart';

enum VaneProtocolMode {
  http3ThenHttp2ThenHttp1,
  http3Only,
  http2ThenHttp1,
  http2Only,
  http1Only,
}

extension VaneProtocolModeName on VaneProtocolMode {
  String get wireName {
    switch (this) {
      case VaneProtocolMode.http3ThenHttp2ThenHttp1:
        return 'http3ThenHttp2ThenHttp1';
      case VaneProtocolMode.http3Only:
        return 'http3Only';
      case VaneProtocolMode.http2ThenHttp1:
        return 'http2ThenHttp1';
      case VaneProtocolMode.http2Only:
        return 'http2Only';
      case VaneProtocolMode.http1Only:
        return 'http1Only';
    }
  }
}

class VaneConfiguration {
  const VaneConfiguration({
    this.baseUrl,
    this.defaultHeaders = const <String, String>{},
    this.dnsOverrides = const <String, String>{},
    this.certificatePins = const <String, List<String>>{},
    this.cookiesEnabled = false,
    this.connectionPoolEnabled = true,
    this.maxIdleConnections = 8,
    this.connectionIdleTimeoutSeconds = 30,
    this.retryMaxAttempts = 1,
    this.retryInitialDelayMillis = 100,
    this.retryMaxDelayMillis = 1000,
    this.retryUnsafeMethods = false,
    this.maxRequestBodyBytes = 10485760,
    this.maxResponseBodyBytes = 10485760,
    this.timeoutSeconds,
    this.followRedirects = true,
    this.userAgent,
    this.protocolMode = VaneProtocolMode.http3Only,
    this.proxyUrl,
    this.proxyAuthorization,
  });

  final String? baseUrl;
  final Map<String, String> defaultHeaders;
  final Map<String, String> dnsOverrides;
  final Map<String, List<String>> certificatePins;
  final bool cookiesEnabled;
  final bool connectionPoolEnabled;
  final int maxIdleConnections;
  final int connectionIdleTimeoutSeconds;
  final int retryMaxAttempts;
  final int retryInitialDelayMillis;
  final int retryMaxDelayMillis;
  final bool retryUnsafeMethods;
  final int maxRequestBodyBytes;
  final int maxResponseBodyBytes;
  final int? timeoutSeconds;
  final bool followRedirects;
  final String? userAgent;
  final VaneProtocolMode protocolMode;
  final String? proxyUrl;
  final String? proxyAuthorization;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'baseUrl': baseUrl,
      'defaultHeaders': defaultHeaders,
      'dnsOverrides': dnsOverrides,
      'certificatePins': certificatePins,
      'cookiesEnabled': cookiesEnabled,
      'connectionPoolEnabled': connectionPoolEnabled,
      'maxIdleConnections': maxIdleConnections,
      'connectionIdleTimeoutSeconds': connectionIdleTimeoutSeconds,
      'retryMaxAttempts': retryMaxAttempts,
      'retryInitialDelayMillis': retryInitialDelayMillis,
      'retryMaxDelayMillis': retryMaxDelayMillis,
      'retryUnsafeMethods': retryUnsafeMethods,
      'maxRequestBodyBytes': maxRequestBodyBytes,
      'maxResponseBodyBytes': maxResponseBodyBytes,
      'timeoutSeconds': timeoutSeconds,
      'followRedirects': followRedirects,
      'userAgent': userAgent,
      'protocolMode': protocolMode.wireName,
      'proxyUrl': proxyUrl,
      'proxyAuthorization': proxyAuthorization,
    };
  }
}

class VaneRequest {
  const VaneRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const <String, String>{},
    this.queryParams = const <String, String>{},
    this.body,
    this.timeoutSeconds,
    this.followRedirects = true,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final Map<String, String> queryParams;
  final Uint8List? body;
  final int? timeoutSeconds;
  final bool followRedirects;

  VaneRequest copyWith({
    String? url,
    String? method,
    Map<String, String>? headers,
    Map<String, String>? queryParams,
    Uint8List? body,
    int? timeoutSeconds,
    bool? followRedirects,
  }) {
    return VaneRequest(
      url: url ?? this.url,
      method: method ?? this.method,
      headers: headers ?? this.headers,
      queryParams: queryParams ?? this.queryParams,
      body: body ?? this.body,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      followRedirects: followRedirects ?? this.followRedirects,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'url': url,
      'method': method,
      'headers': headers,
      'queryParams': queryParams,
      'body': body,
      'timeoutSeconds': timeoutSeconds,
      'followRedirects': followRedirects,
    };
  }
}

class VaneResponse {
  const VaneResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.isSuccess,
    required this.url,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
  final bool isSuccess;
  final String url;

  String get text => utf8.decode(body, allowMalformed: true);

  T json<T>() => jsonDecode(text) as T;

  VaneResponse validateStatus([int min = 200, int max = 299]) {
    if (statusCode < min || statusCode > max) {
      throw VaneHttpException(
        'Request failed with status $statusCode',
        statusCode: statusCode,
        response: this,
      );
    }
    return this;
  }

  static VaneResponse fromMap(Map<Object?, Object?> map) {
    final rawHeaders = (map['headers'] as Map<Object?, Object?>?) ?? const {};
    return VaneResponse(
      statusCode: (map['statusCode'] as num).toInt(),
      headers: rawHeaders.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      body: Uint8List.fromList((map['body'] as Uint8List?) ?? Uint8List(0)),
      isSuccess: map['isSuccess'] as bool? ?? false,
      url: map['url'] as String? ?? '',
    );
  }
}

class VaneHttpException implements Exception {
  const VaneHttpException(this.message, {this.statusCode, this.response});

  final String message;
  final int? statusCode;
  final VaneResponse? response;

  @override
  String toString() => 'VaneHttpException: $message';
}

typedef VaneRequestInterceptor = FutureOr<VaneRequest> Function(VaneRequest);
typedef VaneResponseInterceptor = FutureOr<VaneResponse> Function(VaneResponse);
typedef VaneErrorInterceptor =
    FutureOr<VaneResponse?> Function(Object, StackTrace);

class VaneClient {
  VaneClient({
    VaneConfiguration configuration = const VaneConfiguration(),
    List<VaneRequestInterceptor> requestInterceptors = const [],
    List<VaneResponseInterceptor> responseInterceptors = const [],
    List<VaneErrorInterceptor> errorInterceptors = const [],
    VaneFlutterPlatform? platform,
  }) : _configuration = configuration,
       _requestInterceptors = List<VaneRequestInterceptor>.of(
         requestInterceptors,
       ),
       _responseInterceptors = List<VaneResponseInterceptor>.of(
         responseInterceptors,
       ),
       _errorInterceptors = List<VaneErrorInterceptor>.of(errorInterceptors),
       _platform = platform ?? VaneFlutterPlatform.instance;

  final VaneConfiguration _configuration;
  final List<VaneRequestInterceptor> _requestInterceptors;
  final List<VaneResponseInterceptor> _responseInterceptors;
  final List<VaneErrorInterceptor> _errorInterceptors;
  final VaneFlutterPlatform _platform;
  int? _handle;

  Future<int> _ensureHandle() async {
    return _handle ??= await _platform.createClient(_configuration.toMap());
  }

  VaneRequestBuilder request(String url, {String method = 'GET'}) {
    return VaneRequestBuilder._(this, url, method.toUpperCase());
  }

  Future<VaneResponse> get(String url) => request(url).execute();
  Future<VaneResponse> delete(String url) =>
      request(url, method: 'DELETE').execute();
  Future<VaneResponse> post(String url, {Uint8List? body}) {
    final builder = request(url, method: 'POST');
    if (body != null) {
      builder.body(body);
    }
    return builder.execute();
  }

  Future<VaneResponse> put(String url, {Uint8List? body}) {
    final builder = request(url, method: 'PUT');
    if (body != null) {
      builder.body(body);
    }
    return builder.execute();
  }

  Future<VaneResponse> patch(String url, {Uint8List? body}) {
    final builder = request(url, method: 'PATCH');
    if (body != null) {
      builder.body(body);
    }
    return builder.execute();
  }

  Future<VaneResponse> execute(VaneRequest request) async {
    var interceptedRequest = request;
    for (final interceptor in _requestInterceptors) {
      interceptedRequest = await interceptor(interceptedRequest);
    }

    try {
      final handle = await _ensureHandle();
      var response = await _platform.execute(
        handle,
        interceptedRequest.toMap(),
      );
      for (final interceptor in _responseInterceptors) {
        response = await interceptor(response);
      }
      return response;
    } catch (error, stackTrace) {
      for (final interceptor in _errorInterceptors) {
        final response = await interceptor(error, stackTrace);
        if (response != null) {
          var interceptedResponse = response;
          for (final responseInterceptor in _responseInterceptors) {
            interceptedResponse = await responseInterceptor(
              interceptedResponse,
            );
          }
          return interceptedResponse;
        }
      }
      rethrow;
    }
  }

  Future<void> close() async {
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      await _platform.closeClient(handle);
    }
  }
}

class VaneRequestBuilder {
  VaneRequestBuilder._(this._client, String url, String method)
    : _request = VaneRequest(url: url, method: method);

  final VaneClient _client;
  VaneRequest _request;

  VaneRequestBuilder headers(Map<String, String> headers) {
    _request = _request.copyWith(headers: Map<String, String>.of(headers));
    return this;
  }

  VaneRequestBuilder header(String key, String value) {
    _request = _request.copyWith(
      headers: <String, String>{..._request.headers, key: value},
    );
    return this;
  }

  VaneRequestBuilder queryParams(Map<String, String> params) {
    _request = _request.copyWith(queryParams: Map<String, String>.of(params));
    return this;
  }

  VaneRequestBuilder queryParam(String key, String value) {
    _request = _request.copyWith(
      queryParams: <String, String>{..._request.queryParams, key: value},
    );
    return this;
  }

  VaneRequestBuilder body(Uint8List body) {
    _request = _request.copyWith(body: body);
    return this;
  }

  VaneRequestBuilder textBody(
    String text, {
    Encoding encoding = utf8,
    String contentType = 'text/plain; charset=utf-8',
  }) {
    return body(
      Uint8List.fromList(encoding.encode(text)),
    )._defaultHeader('Content-Type', contentType);
  }

  VaneRequestBuilder jsonBody(Object? value) {
    return body(
      Uint8List.fromList(utf8.encode(jsonEncode(value))),
    )._defaultHeader('Content-Type', 'application/json');
  }

  VaneRequestBuilder formBody(Map<String, String> fields) {
    final entries = fields.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final encoded = entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&')
        .replaceAll('%20', '+');
    return body(
      Uint8List.fromList(utf8.encode(encoded)),
    )._defaultHeader('Content-Type', 'application/x-www-form-urlencoded');
  }

  VaneRequestBuilder timeout(int seconds) {
    _request = _request.copyWith(timeoutSeconds: seconds);
    return this;
  }

  VaneRequestBuilder followRedirects(bool follow) {
    _request = _request.copyWith(followRedirects: follow);
    return this;
  }

  Future<VaneResponse> execute() => _client.execute(_request);

  Future<VaneResponse> validateStatus([int min = 200, int max = 299]) async {
    return (await execute()).validateStatus(min, max);
  }

  Future<Uint8List> responseBytes() async => (await validateStatus()).body;
  Future<String> responseString() async => (await validateStatus()).text;
  Future<T> responseJson<T>() async => (await validateStatus()).json<T>();

  VaneRequestBuilder _defaultHeader(String key, String value) {
    final hasHeader = _request.headers.keys.any(
      (existing) => existing.toLowerCase() == key.toLowerCase(),
    );
    if (!hasHeader) {
      header(key, value);
    }
    return this;
  }
}
