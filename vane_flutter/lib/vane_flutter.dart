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
    this.cookiePersistencePath,
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
  final String? cookiePersistencePath;
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
      'cookiePersistencePath': cookiePersistencePath,
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
    this.bodyFilePath,
    this.responseBodyPath,
    this.cancelToken,
    this.onUploadProgress,
    this.onDownloadProgress,
    this.timeoutSeconds,
    this.followRedirects = true,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final Map<String, String> queryParams;
  final Uint8List? body;
  final String? bodyFilePath;
  final String? responseBodyPath;
  final VaneCancelToken? cancelToken;
  final VaneProgressCallback? onUploadProgress;
  final VaneProgressCallback? onDownloadProgress;
  final int? timeoutSeconds;
  final bool followRedirects;

  VaneRequest copyWith({
    String? url,
    String? method,
    Map<String, String>? headers,
    Map<String, String>? queryParams,
    Uint8List? body,
    String? bodyFilePath,
    String? responseBodyPath,
    VaneCancelToken? cancelToken,
    VaneProgressCallback? onUploadProgress,
    VaneProgressCallback? onDownloadProgress,
    int? timeoutSeconds,
    bool? followRedirects,
  }) {
    return VaneRequest(
      url: url ?? this.url,
      method: method ?? this.method,
      headers: headers ?? this.headers,
      queryParams: queryParams ?? this.queryParams,
      body: body ?? this.body,
      bodyFilePath: bodyFilePath ?? this.bodyFilePath,
      responseBodyPath: responseBodyPath ?? this.responseBodyPath,
      cancelToken: cancelToken ?? this.cancelToken,
      onUploadProgress: onUploadProgress ?? this.onUploadProgress,
      onDownloadProgress: onDownloadProgress ?? this.onDownloadProgress,
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
      'bodyFilePath': bodyFilePath,
      'responseBodyPath': responseBodyPath,
      'cancelTokenId': cancelToken?._id,
      'progressId': null,
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
    this.bodyFilePath,
    required this.isSuccess,
    required this.url,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
  final String? bodyFilePath;
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
      bodyFilePath: map['bodyFilePath'] as String?,
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
typedef VaneProgressCallback = void Function(int transferred, int total);

class VaneRequestOptions {
  const VaneRequestOptions({
    this.headers = const <String, String>{},
    this.queryParams = const <String, String>{},
    this.timeoutSeconds,
    this.followRedirects,
    this.cancelToken,
    this.onUploadProgress,
    this.onDownloadProgress,
    this.responseBodyPath,
  });

  final Map<String, String> headers;
  final Map<String, String> queryParams;
  final int? timeoutSeconds;
  final bool? followRedirects;
  final VaneCancelToken? cancelToken;
  final VaneProgressCallback? onUploadProgress;
  final VaneProgressCallback? onDownloadProgress;
  final String? responseBodyPath;

  VaneRequestBuilder applyTo(VaneRequestBuilder builder) {
    if (headers.isNotEmpty) {
      builder.headers(headers);
    }
    if (queryParams.isNotEmpty) {
      builder.queryParams(queryParams);
    }
    final timeout = timeoutSeconds;
    if (timeout != null) {
      builder.timeout(timeout);
    }
    final redirects = followRedirects;
    if (redirects != null) {
      builder.followRedirects(redirects);
    }
    final token = cancelToken;
    if (token != null) {
      builder.cancelToken(token);
    }
    final upload = onUploadProgress;
    if (upload != null) {
      builder.onUploadProgress(upload);
    }
    final download = onDownloadProgress;
    if (download != null) {
      builder.onDownloadProgress(download);
    }
    final outputPath = responseBodyPath;
    if (outputPath != null) {
      builder.downloadToFile(outputPath);
    }
    return builder;
  }
}

class VaneMultipartFile {
  const VaneMultipartFile({
    required this.fieldName,
    required this.bytes,
    this.fileName,
    this.contentType = 'application/octet-stream',
  });

  final String fieldName;
  final Uint8List bytes;
  final String? fileName;
  final String contentType;
}

class VaneProgress {
  const VaneProgress({
    required this.uploadSent,
    required this.uploadTotal,
    required this.downloadReceived,
    required this.downloadTotal,
    required this.done,
  });

  final int uploadSent;
  final int uploadTotal;
  final int downloadReceived;
  final int downloadTotal;
  final bool done;
}

class VaneCancelToken {
  VaneFlutterPlatform? _platform;
  int? _id;

  bool get isStarted => _id != null;

  Future<void> cancel() async {
    final id = _id;
    final platform = _platform;
    if (id != null && platform != null) {
      await platform.cancelToken(id);
    }
  }

  Future<void> dispose() async {
    final id = _id;
    final platform = _platform;
    _id = null;
    _platform = null;
    if (id != null && platform != null) {
      await platform.freeCancelToken(id);
    }
  }
}

class Vane {
  Vane._();

  static VaneClient _shared = VaneClient();

  static VaneClient get shared => _shared;

  static Future<void> configure({
    VaneConfiguration configuration = const VaneConfiguration(),
    List<VaneRequestInterceptor> requestInterceptors = const [],
    List<VaneResponseInterceptor> responseInterceptors = const [],
    List<VaneErrorInterceptor> errorInterceptors = const [],
  }) async {
    await _shared.close();
    _shared = VaneClient(
      configuration: configuration,
      requestInterceptors: requestInterceptors,
      responseInterceptors: responseInterceptors,
      errorInterceptors: errorInterceptors,
    );
  }

  static VaneRequestBuilder request(String url, {String method = 'GET'}) {
    return _shared.request(url, method: method);
  }

  static void addRequestInterceptor(VaneRequestInterceptor interceptor) {
    _shared.addRequestInterceptor(interceptor);
  }

  static void addResponseInterceptor(VaneResponseInterceptor interceptor) {
    _shared.addResponseInterceptor(interceptor);
  }

  static void addErrorInterceptor(VaneErrorInterceptor interceptor) {
    _shared.addErrorInterceptor(interceptor);
  }

  static void clearInterceptors() {
    _shared.clearInterceptors();
  }

  static Future<VaneResponse> get(
    String url, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.get(url, options: options);
  }

  static Future<VaneResponse> delete(
    String url, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.delete(url, options: options);
  }

  static Future<VaneResponse> post(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.post(url, body: body, options: options);
  }

  static Future<VaneResponse> put(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.put(url, body: body, options: options);
  }

  static Future<VaneResponse> patch(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.patch(url, body: body, options: options);
  }

  static Future<VaneResponse> postJson(
    String url,
    Object? value, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.postJson(url, value, options: options);
  }

  static Future<VaneResponse> postForm(
    String url,
    Map<String, String> fields, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.postForm(url, fields, options: options);
  }

  static Future<VaneResponse> uploadFile(
    String url,
    String path, {
    String method = 'POST',
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.uploadFile(url, path, method: method, options: options);
  }

  static Future<VaneResponse> download(
    String url,
    String outputPath, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.download(url, outputPath, options: options);
  }

  static Future<void> setCertificatePins(String host, List<String> pins) {
    return _shared.setCertificatePins(host, pins);
  }

  static Future<void> clearCertificatePins(String host) {
    return _shared.clearCertificatePins(host);
  }

  static Future<void> close() => _shared.close();
}

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

  VaneClient addRequestInterceptor(VaneRequestInterceptor interceptor) {
    _requestInterceptors.add(interceptor);
    return this;
  }

  VaneClient addResponseInterceptor(VaneResponseInterceptor interceptor) {
    _responseInterceptors.add(interceptor);
    return this;
  }

  VaneClient addErrorInterceptor(VaneErrorInterceptor interceptor) {
    _errorInterceptors.add(interceptor);
    return this;
  }

  VaneClient clearInterceptors() {
    _requestInterceptors.clear();
    _responseInterceptors.clear();
    _errorInterceptors.clear();
    return this;
  }

  Future<void> setCertificatePins(String host, List<String> pins) async {
    final handle = await _ensureHandle();
    await _platform.setCertificatePins(handle, host, pins);
  }

  Future<void> clearCertificatePins(String host) {
    return setCertificatePins(host, const <String>[]);
  }

  Future<VaneResponse> get(
    String url, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options.applyTo(request(url)).execute();
  }

  Future<VaneResponse> delete(
    String url, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options.applyTo(request(url, method: 'DELETE')).execute();
  }

  Future<VaneResponse> post(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    final builder = options.applyTo(request(url, method: 'POST'));
    if (body != null) {
      builder.body(body);
    }
    return builder.execute();
  }

  Future<VaneResponse> put(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    final builder = options.applyTo(request(url, method: 'PUT'));
    if (body != null) {
      builder.body(body);
    }
    return builder.execute();
  }

  Future<VaneResponse> patch(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    final builder = options.applyTo(request(url, method: 'PATCH'));
    if (body != null) {
      builder.body(body);
    }
    return builder.execute();
  }

  Future<VaneResponse> postJson(
    String url,
    Object? value, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options
        .applyTo(request(url, method: 'POST'))
        .jsonBody(value)
        .execute();
  }

  Future<VaneResponse> postForm(
    String url,
    Map<String, String> fields, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options
        .applyTo(request(url, method: 'POST'))
        .formBody(fields)
        .execute();
  }

  Future<VaneResponse> uploadFile(
    String url,
    String path, {
    String method = 'POST',
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options
        .applyTo(request(url, method: method))
        .bodyFile(path)
        .execute();
  }

  Future<VaneResponse> download(
    String url,
    String outputPath, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options.applyTo(request(url)).downloadToFile(outputPath).execute();
  }

  Future<VaneResponse> execute(VaneRequest request) async {
    var interceptedRequest = request;
    for (final interceptor in List<VaneRequestInterceptor>.of(
      _requestInterceptors,
    )) {
      interceptedRequest = await interceptor(interceptedRequest);
    }

    Timer? progressTimer;
    int? progressId;
    try {
      final handle = await _ensureHandle();
      final cancelToken = interceptedRequest.cancelToken;
      if (cancelToken != null && cancelToken._id == null) {
        cancelToken
          .._platform = _platform
          .._id = await _platform.createCancelToken();
      }
      if (interceptedRequest.onUploadProgress != null ||
          interceptedRequest.onDownloadProgress != null) {
        progressId = await _platform.createProgress();
        progressTimer = Timer.periodic(const Duration(milliseconds: 100), (
          _,
        ) async {
          final id = progressId;
          if (id == null) {
            return;
          }
          final progress = await _platform.progressSnapshot(id);
          interceptedRequest.onUploadProgress?.call(
            progress.uploadSent,
            progress.uploadTotal,
          );
          interceptedRequest.onDownloadProgress?.call(
            progress.downloadReceived,
            progress.downloadTotal,
          );
          if (progress.done) {
            progressTimer?.cancel();
          }
        });
      }
      final requestMap = interceptedRequest.toMap();
      requestMap['progressId'] = progressId;
      var response = await _platform.execute(handle, requestMap);
      for (final interceptor in List<VaneResponseInterceptor>.of(
        _responseInterceptors,
      )) {
        response = await interceptor(response);
      }
      return response;
    } catch (error, stackTrace) {
      for (final interceptor in List<VaneErrorInterceptor>.of(
        _errorInterceptors,
      )) {
        final response = await interceptor(error, stackTrace);
        if (response != null) {
          var interceptedResponse = response;
          for (final responseInterceptor in List<VaneResponseInterceptor>.of(
            _responseInterceptors,
          )) {
            interceptedResponse = await responseInterceptor(
              interceptedResponse,
            );
          }
          return interceptedResponse;
        }
      }
      rethrow;
    } finally {
      progressTimer?.cancel();
      if (progressId != null) {
        final progress = await _platform.progressSnapshot(progressId);
        interceptedRequest.onUploadProgress?.call(
          progress.uploadSent,
          progress.uploadTotal,
        );
        interceptedRequest.onDownloadProgress?.call(
          progress.downloadReceived,
          progress.downloadTotal,
        );
        await _platform.freeProgress(progressId);
      }
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
    _request = VaneRequest(
      url: _request.url,
      method: _request.method,
      headers: _request.headers,
      queryParams: _request.queryParams,
      body: body,
      responseBodyPath: _request.responseBodyPath,
      cancelToken: _request.cancelToken,
      onUploadProgress: _request.onUploadProgress,
      onDownloadProgress: _request.onDownloadProgress,
      timeoutSeconds: _request.timeoutSeconds,
      followRedirects: _request.followRedirects,
    );
    return this;
  }

  VaneRequestBuilder bodyFile(String path) {
    _request = VaneRequest(
      url: _request.url,
      method: _request.method,
      headers: _request.headers,
      queryParams: _request.queryParams,
      bodyFilePath: path,
      responseBodyPath: _request.responseBodyPath,
      cancelToken: _request.cancelToken,
      onUploadProgress: _request.onUploadProgress,
      onDownloadProgress: _request.onDownloadProgress,
      timeoutSeconds: _request.timeoutSeconds,
      followRedirects: _request.followRedirects,
    );
    return this;
  }

  VaneRequestBuilder downloadToFile(String path) {
    _request = _request.copyWith(responseBodyPath: path);
    return this;
  }

  VaneRequestBuilder cancelToken(VaneCancelToken token) {
    _request = _request.copyWith(cancelToken: token);
    return this;
  }

  VaneRequestBuilder onUploadProgress(VaneProgressCallback callback) {
    _request = _request.copyWith(onUploadProgress: callback);
    return this;
  }

  VaneRequestBuilder onDownloadProgress(VaneProgressCallback callback) {
    _request = _request.copyWith(onDownloadProgress: callback);
    return this;
  }

  VaneRequestBuilder multipart({
    Map<String, String> fields = const <String, String>{},
    Map<String, Uint8List> files = const <String, Uint8List>{},
    List<VaneMultipartFile> fileParts = const <VaneMultipartFile>[],
  }) {
    final boundary = 'vane-${DateTime.now().microsecondsSinceEpoch}';
    final body = BytesBuilder();
    for (final entry in fields.entries) {
      body
        ..add(utf8.encode('--$boundary\r\n'))
        ..add(
          utf8.encode(
            'Content-Disposition: form-data; name="${entry.key}"\r\n\r\n',
          ),
        )
        ..add(utf8.encode(entry.value))
        ..add(utf8.encode('\r\n'));
    }
    for (final entry in files.entries) {
      _appendMultipartFile(
        body,
        boundary,
        fieldName: entry.key,
        fileName: entry.key,
        contentType: 'application/octet-stream',
        bytes: entry.value,
      );
    }
    for (final part in fileParts) {
      _appendMultipartFile(
        body,
        boundary,
        fieldName: part.fieldName,
        fileName: part.fileName ?? part.fieldName,
        contentType: part.contentType,
        bytes: part.bytes,
      );
    }
    body.add(utf8.encode('--$boundary--\r\n'));
    return this
        .body(body.toBytes())
        ._defaultHeader(
          'Content-Type',
          'multipart/form-data; boundary=$boundary',
        );
  }

  void _appendMultipartFile(
    BytesBuilder body,
    String boundary, {
    required String fieldName,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
  }) {
    body
      ..add(utf8.encode('--$boundary\r\n'))
      ..add(
        utf8.encode(
          'Content-Disposition: form-data; name="$fieldName"; filename="$fileName"\r\n',
        ),
      )
      ..add(utf8.encode('Content-Type: $contentType\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n'));
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
