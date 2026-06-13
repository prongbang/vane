import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'vane_flutter.dart';
import 'vane_flutter_platform_interface.dart';

final class _VaneFfiString extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int len;
}

final class _VaneFfiStringPair extends Struct {
  external _VaneFfiString key;
  external _VaneFfiString value;
}

final class _VaneFfiStringList extends Struct {
  external Pointer<_VaneFfiString> values;

  @Size()
  external int len;
}

final class _VaneFfiStringListPair extends Struct {
  external _VaneFfiString key;
  external _VaneFfiStringList values;
}

final class _VaneFfiClientConfig extends Struct {
  external _VaneFfiString baseUrl;
  external Pointer<_VaneFfiStringPair> defaultHeaders;

  @Size()
  external int defaultHeadersLen;

  external Pointer<_VaneFfiStringPair> dnsOverrides;

  @Size()
  external int dnsOverridesLen;

  external Pointer<_VaneFfiStringListPair> certificatePins;

  @Size()
  external int certificatePinsLen;

  @Bool()
  external bool cookiesEnabled;

  @Bool()
  external bool connectionPoolEnabled;

  @Uint64()
  external int maxIdleConnections;

  @Uint64()
  external int connectionIdleTimeoutSeconds;

  @Uint64()
  external int retryMaxAttempts;

  @Uint64()
  external int retryInitialDelayMillis;

  @Uint64()
  external int retryMaxDelayMillis;

  @Bool()
  external bool retryUnsafeMethods;

  @Uint64()
  external int maxRequestBodyBytes;

  @Uint64()
  external int maxResponseBodyBytes;

  @Int64()
  external int timeoutSeconds;

  @Bool()
  external bool followRedirects;

  external _VaneFfiString userAgent;

  @Uint8()
  external int protocolMode;

  external _VaneFfiString proxyUrl;
  external _VaneFfiString proxyAuthorization;
}

final class _VaneFfiRequest extends Struct {
  external _VaneFfiString url;
  external _VaneFfiString method;
  external Pointer<_VaneFfiStringPair> headers;

  @Size()
  external int headersLen;

  external Pointer<_VaneFfiStringPair> queryParams;

  @Size()
  external int queryParamsLen;

  @Int64()
  external int timeoutSeconds;

  @Bool()
  external bool followRedirects;
}

final class _VaneFfiBuffer extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int len;

  @Size()
  external int cap;
}

final class _VaneFfiHeader extends Struct {
  external _VaneFfiBuffer key;
  external _VaneFfiBuffer value;
}

final class _VaneFfiHeaderArray extends Struct {
  external Pointer<_VaneFfiHeader> data;

  @Size()
  external int len;

  @Size()
  external int cap;
}

final class _VaneFfiResponse extends Struct {
  @Uint16()
  external int statusCode;

  @Bool()
  external bool isSuccess;

  external _VaneFfiHeaderArray headers;
  external _VaneFfiBuffer body;
  external _VaneFfiBuffer url;
  external _VaneFfiBuffer error;
}

typedef _ClientCreateNative =
    Uint64 Function(Pointer<_VaneFfiClientConfig>, Pointer<_VaneFfiBuffer>);
typedef _ClientCreateDart =
    int Function(Pointer<_VaneFfiClientConfig>, Pointer<_VaneFfiBuffer>);
typedef _ClientCloseNative = Void Function(Uint64);
typedef _ClientCloseDart = void Function(int);
typedef _ExecuteNative =
    Pointer<_VaneFfiResponse> Function(
      Uint64,
      Pointer<_VaneFfiRequest>,
      Pointer<Uint8>,
      Size,
    );
typedef _ExecuteDart =
    Pointer<_VaneFfiResponse> Function(
      int,
      Pointer<_VaneFfiRequest>,
      Pointer<Uint8>,
      int,
    );
typedef _ResponseFreeNative = Void Function(Pointer<_VaneFfiResponse>);
typedef _ResponseFreeDart = void Function(Pointer<_VaneFfiResponse>);
typedef _BufferFreeNative = Void Function(_VaneFfiBuffer);
typedef _BufferFreeDart = void Function(_VaneFfiBuffer);

class FfiVaneFlutter extends VaneFlutterPlatform {
  FfiVaneFlutter({this._library});

  final DynamicLibrary? _library;
  _VaneFfiBindings? _bindings;

  _VaneFfiBindings get _nativeBindings =>
      _bindings ??= _VaneFfiBindings(_library ?? _openLibrary());

  @override
  Future<int> createClient(Map<String, Object?> configuration) async {
    return _nativeBindings.createClient(configuration);
  }

  @override
  Future<VaneResponse> execute(int handle, Map<String, Object?> request) {
    return Isolate.run(() => _VaneFfiBindings.shared.execute(handle, request));
  }

  @override
  Future<void> closeClient(int handle) async {
    _nativeBindings.closeClient(handle);
  }

  static DynamicLibrary _openLibrary() {
    if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libvane.so');
    }
    throw UnsupportedError('Vane FFI is not supported on this platform.');
  }
}

class _VaneFfiBindings {
  _VaneFfiBindings(DynamicLibrary library)
    : _clientCreate = library
          .lookupFunction<_ClientCreateNative, _ClientCreateDart>(
            'vane_ffi_client_create',
          ),
      _clientClose = library
          .lookupFunction<_ClientCloseNative, _ClientCloseDart>(
            'vane_ffi_client_close',
          ),
      _execute = library.lookupFunction<_ExecuteNative, _ExecuteDart>(
        'vane_ffi_execute',
      ),
      _responseFree = library
          .lookupFunction<_ResponseFreeNative, _ResponseFreeDart>(
            'vane_ffi_response_free',
          ),
      _bufferFree = library.lookupFunction<_BufferFreeNative, _BufferFreeDart>(
        'vane_ffi_buffer_free',
      );

  static final shared = _VaneFfiBindings(FfiVaneFlutter._openLibrary());

  final _ClientCreateDart _clientCreate;
  final _ClientCloseDart _clientClose;
  final _ExecuteDart _execute;
  final _ResponseFreeDart _responseFree;
  final _BufferFreeDart _bufferFree;

  int createClient(Map<String, Object?> configuration) {
    final config = _NativeConfig(configuration);
    final error = calloc<_VaneFfiBuffer>();
    try {
      final handle = _clientCreate(config.pointer, error);
      final message = _readString(error.ref);
      if (message.isNotEmpty) {
        _bufferFree(error.ref);
        throw VaneHttpException(message);
      }
      if (handle == 0) {
        throw const VaneHttpException('Native Vane client creation failed.');
      }
      return handle;
    } finally {
      calloc.free(error);
      config.free();
    }
  }

  VaneResponse execute(int handle, Map<String, Object?> request) {
    final nativeRequest = _NativeRequest(request);
    Pointer<_VaneFfiResponse> responsePtr = nullptr;
    try {
      responsePtr = _execute(
        handle,
        nativeRequest.pointer,
        nativeRequest.body.pointer,
        nativeRequest.body.length,
      );
      if (responsePtr == nullptr) {
        throw const VaneHttpException('Native Vane request returned null.');
      }
      final response = responsePtr.ref;
      final error = _readString(response.error);
      if (error.isNotEmpty) {
        throw VaneHttpException(error);
      }
      return VaneResponse(
        statusCode: response.statusCode,
        headers: _readHeaders(response.headers),
        body: _readBytes(response.body),
        isSuccess: response.isSuccess,
        url: _readString(response.url),
      );
    } finally {
      if (responsePtr != nullptr) {
        _responseFree(responsePtr);
      }
      nativeRequest.free();
    }
  }

  void closeClient(int handle) {
    _clientClose(handle);
  }

  Map<String, String> _readHeaders(_VaneFfiHeaderArray headers) {
    if (headers.data == nullptr || headers.len == 0) {
      return const <String, String>{};
    }
    final map = <String, String>{};
    for (var index = 0; index < headers.len; index += 1) {
      final header = (headers.data + index).ref;
      map[_readString(header.key)] = _readString(header.value);
    }
    return map;
  }

  String _readString(_VaneFfiBuffer buffer) {
    final bytes = _readBytes(buffer);
    if (bytes.isEmpty) {
      return '';
    }
    return utf8.decode(bytes);
  }

  Uint8List _readBytes(_VaneFfiBuffer buffer) {
    if (buffer.data == nullptr || buffer.len == 0) {
      return Uint8List(0);
    }
    return Uint8List.fromList(buffer.data.asTypedList(buffer.len));
  }
}

class _NativeConfig {
  _NativeConfig(Map<String, Object?> config)
    : pointer = calloc<_VaneFfiClientConfig>(),
      baseUrl = _NativeString(config['baseUrl'] as String?),
      defaultHeaders = _NativeStringPairArray(
        _stringMap(config['defaultHeaders']),
      ),
      dnsOverrides = _NativeStringPairArray(_stringMap(config['dnsOverrides'])),
      certificatePins = _NativeStringListPairArray(
        _stringListMap(config['certificatePins']),
      ),
      userAgent = _NativeString(config['userAgent'] as String?),
      proxyUrl = _NativeString(config['proxyUrl'] as String?),
      proxyAuthorization = _NativeString(
        config['proxyAuthorization'] as String?,
      ) {
    final ref = pointer.ref;
    ref.baseUrl = baseUrl.value;
    ref.defaultHeaders = defaultHeaders.pointer;
    ref.defaultHeadersLen = defaultHeaders.length;
    ref.dnsOverrides = dnsOverrides.pointer;
    ref.dnsOverridesLen = dnsOverrides.length;
    ref.certificatePins = certificatePins.pointer;
    ref.certificatePinsLen = certificatePins.length;
    ref.cookiesEnabled = config['cookiesEnabled'] as bool? ?? false;
    ref.connectionPoolEnabled =
        config['connectionPoolEnabled'] as bool? ?? true;
    ref.maxIdleConnections = config['maxIdleConnections'] as int? ?? 8;
    ref.connectionIdleTimeoutSeconds =
        config['connectionIdleTimeoutSeconds'] as int? ?? 30;
    ref.retryMaxAttempts = config['retryMaxAttempts'] as int? ?? 1;
    ref.retryInitialDelayMillis =
        config['retryInitialDelayMillis'] as int? ?? 100;
    ref.retryMaxDelayMillis = config['retryMaxDelayMillis'] as int? ?? 1000;
    ref.retryUnsafeMethods = config['retryUnsafeMethods'] as bool? ?? false;
    ref.maxRequestBodyBytes = config['maxRequestBodyBytes'] as int? ?? 10485760;
    ref.maxResponseBodyBytes =
        config['maxResponseBodyBytes'] as int? ?? 10485760;
    ref.timeoutSeconds = config['timeoutSeconds'] as int? ?? -1;
    ref.followRedirects = config['followRedirects'] as bool? ?? true;
    ref.userAgent = userAgent.value;
    ref.protocolMode = _protocolMode(config['protocolMode'] as String?);
    ref.proxyUrl = proxyUrl.value;
    ref.proxyAuthorization = proxyAuthorization.value;
  }

  final Pointer<_VaneFfiClientConfig> pointer;
  final _NativeString baseUrl;
  final _NativeStringPairArray defaultHeaders;
  final _NativeStringPairArray dnsOverrides;
  final _NativeStringListPairArray certificatePins;
  final _NativeString userAgent;
  final _NativeString proxyUrl;
  final _NativeString proxyAuthorization;

  void free() {
    proxyAuthorization.free();
    proxyUrl.free();
    userAgent.free();
    certificatePins.free();
    dnsOverrides.free();
    defaultHeaders.free();
    baseUrl.free();
    calloc.free(pointer);
  }
}

class _NativeRequest {
  _NativeRequest(Map<String, Object?> request)
    : pointer = calloc<_VaneFfiRequest>(),
      url = _NativeString(request['url'] as String? ?? ''),
      method = _NativeString(request['method'] as String? ?? 'GET'),
      headers = _NativeStringPairArray(_stringMap(request['headers'])),
      queryParams = _NativeStringPairArray(_stringMap(request['queryParams'])),
      body = _NativeBytes((request['body'] as Uint8List?) ?? Uint8List(0)) {
    final ref = pointer.ref;
    ref.url = url.value;
    ref.method = method.value;
    ref.headers = headers.pointer;
    ref.headersLen = headers.length;
    ref.queryParams = queryParams.pointer;
    ref.queryParamsLen = queryParams.length;
    ref.timeoutSeconds = request['timeoutSeconds'] as int? ?? -1;
    ref.followRedirects = request['followRedirects'] as bool? ?? true;
  }

  final Pointer<_VaneFfiRequest> pointer;
  final _NativeString url;
  final _NativeString method;
  final _NativeStringPairArray headers;
  final _NativeStringPairArray queryParams;
  final _NativeBytes body;

  void free() {
    body.free();
    queryParams.free();
    headers.free();
    method.free();
    url.free();
    calloc.free(pointer);
  }
}

class _NativeStringPairArray {
  _NativeStringPairArray(Map<String, String> values)
    : length = values.length,
      pointer = values.isEmpty
          ? nullptr
          : calloc<_VaneFfiStringPair>(values.length) {
    var index = 0;
    for (final entry in values.entries) {
      final key = _NativeString(entry.key);
      final value = _NativeString(entry.value);
      strings
        ..add(key)
        ..add(value);
      pointer[index].key = key.value;
      pointer[index].value = value.value;
      index += 1;
    }
  }

  final Pointer<_VaneFfiStringPair> pointer;
  final int length;
  final List<_NativeString> strings = <_NativeString>[];

  void free() {
    for (final string in strings.reversed) {
      string.free();
    }
    if (pointer != nullptr) {
      calloc.free(pointer);
    }
  }
}

class _NativeStringListPairArray {
  _NativeStringListPairArray(Map<String, List<String>> values)
    : length = values.length,
      pointer = values.isEmpty
          ? nullptr
          : calloc<_VaneFfiStringListPair>(values.length) {
    var index = 0;
    for (final entry in values.entries) {
      final key = _NativeString(entry.key);
      final list = _NativeStringArray(entry.value);
      keys.add(key);
      lists.add(list);
      pointer[index].key = key.value;
      pointer[index].values.values = list.pointer;
      pointer[index].values.len = list.length;
      index += 1;
    }
  }

  final Pointer<_VaneFfiStringListPair> pointer;
  final int length;
  final List<_NativeString> keys = <_NativeString>[];
  final List<_NativeStringArray> lists = <_NativeStringArray>[];

  void free() {
    for (final list in lists.reversed) {
      list.free();
    }
    for (final key in keys.reversed) {
      key.free();
    }
    if (pointer != nullptr) {
      calloc.free(pointer);
    }
  }
}

class _NativeStringArray {
  _NativeStringArray(List<String> values)
    : length = values.length,
      pointer = values.isEmpty
          ? nullptr
          : calloc<_VaneFfiString>(values.length) {
    for (var index = 0; index < values.length; index += 1) {
      final string = _NativeString(values[index]);
      strings.add(string);
      pointer[index] = string.value;
    }
  }

  final Pointer<_VaneFfiString> pointer;
  final int length;
  final List<_NativeString> strings = <_NativeString>[];

  void free() {
    for (final string in strings.reversed) {
      string.free();
    }
    if (pointer != nullptr) {
      calloc.free(pointer);
    }
  }
}

class _NativeString {
  _NativeString(String? value)
    : bytes = _NativeBytes(
        value == null ? Uint8List(0) : Uint8List.fromList(utf8.encode(value)),
      );

  final _NativeBytes bytes;

  _VaneFfiString get value {
    final string = calloc<_VaneFfiString>();
    try {
      string.ref.data = bytes.pointer;
      string.ref.len = bytes.length;
      return string.ref;
    } finally {
      calloc.free(string);
    }
  }

  void free() {
    bytes.free();
  }
}

class _NativeBytes {
  _NativeBytes(List<int> bytes)
    : length = bytes.length,
      pointer = bytes.isEmpty ? nullptr : calloc<Uint8>(bytes.length) {
    if (bytes.isNotEmpty) {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
    }
  }

  final Pointer<Uint8> pointer;
  final int length;

  void free() {
    if (pointer != nullptr) {
      calloc.free(pointer);
    }
  }
}

Map<String, String> _stringMap(Object? value) {
  final map = (value as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
  return map.map((key, value) => MapEntry(key.toString(), value.toString()));
}

Map<String, List<String>> _stringListMap(Object? value) {
  final map = (value as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
  return map.map((key, value) {
    final values = (value as List<Object?>?) ?? const <Object?>[];
    return MapEntry(
      key.toString(),
      values.map((item) => item.toString()).toList(),
    );
  });
}

int _protocolMode(String? value) {
  switch (value) {
    case 'http3ThenHttp2ThenHttp1':
      return 0;
    case 'http3Only':
    case null:
      return 1;
    case 'http2ThenHttp1':
      return 2;
    case 'http2Only':
      return 3;
    case 'http1Only':
      return 4;
    default:
      throw VaneHttpException('Invalid Vane protocol mode: $value');
  }
}
