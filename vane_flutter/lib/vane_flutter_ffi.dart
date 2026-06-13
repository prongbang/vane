import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'vane_flutter.dart';
import 'vane_flutter_platform_interface.dart';

final class _VaneFfiBuffer extends Struct {
  external Pointer<Uint8> data;

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

  external _VaneFfiBuffer headersJson;
  external _VaneFfiBuffer body;
  external _VaneFfiBuffer url;
  external _VaneFfiBuffer error;
}

typedef _ClientCreateNative =
    Uint64 Function(Pointer<Uint8>, Size, Pointer<_VaneFfiBuffer>);
typedef _ClientCreateDart =
    int Function(Pointer<Uint8>, int, Pointer<_VaneFfiBuffer>);
typedef _ClientCloseNative = Void Function(Uint64);
typedef _ClientCloseDart = void Function(int);
typedef _ExecuteNative =
    Pointer<_VaneFfiResponse> Function(
      Uint64,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
    );
typedef _ExecuteDart =
    Pointer<_VaneFfiResponse> Function(
      int,
      Pointer<Uint8>,
      int,
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
    final jsonBytes = utf8.encode(jsonEncode(configuration));
    final json = _NativeBytes(jsonBytes);
    final error = calloc<_VaneFfiBuffer>();
    try {
      final handle = _clientCreate(json.pointer, json.length, error);
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
      json.free();
    }
  }

  VaneResponse execute(int handle, Map<String, Object?> request) {
    final body = request['body'] as Uint8List?;
    final requestJson = Map<String, Object?>.of(request)..remove('body');
    requestJson['body'] = null;
    final jsonBytes = utf8.encode(jsonEncode(requestJson));
    final json = _NativeBytes(jsonBytes);
    final nativeBody = _NativeBytes(body ?? Uint8List(0));
    Pointer<_VaneFfiResponse> responsePtr = nullptr;
    try {
      responsePtr = _execute(
        handle,
        json.pointer,
        json.length,
        nativeBody.pointer,
        nativeBody.length,
      );
      if (responsePtr == nullptr) {
        throw const VaneHttpException('Native Vane request returned null.');
      }
      final response = responsePtr.ref;
      final error = _readString(response.error);
      if (error.isNotEmpty) {
        throw VaneHttpException(error);
      }
      final headers = _decodeHeaders(response.headersJson);
      return VaneResponse(
        statusCode: response.statusCode,
        headers: headers,
        body: _readBytes(response.body),
        isSuccess: response.isSuccess,
        url: _readString(response.url),
      );
    } finally {
      if (responsePtr != nullptr) {
        _responseFree(responsePtr);
      }
      nativeBody.free();
      json.free();
    }
  }

  void closeClient(int handle) {
    _clientClose(handle);
  }

  Map<String, String> _decodeHeaders(_VaneFfiBuffer buffer) {
    final text = _readString(buffer);
    if (text.isEmpty) {
      return const <String, String>{};
    }
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    return decoded.map((key, value) => MapEntry(key, value.toString()));
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
