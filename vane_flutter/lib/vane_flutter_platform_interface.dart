import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'vane_flutter.dart';
import 'vane_flutter_ffi.dart';

abstract class VaneFlutterPlatform extends PlatformInterface {
  VaneFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static VaneFlutterPlatform _instance = FfiVaneFlutter();

  static VaneFlutterPlatform get instance => _instance;

  static set instance(VaneFlutterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<int> createClient(Map<String, Object?> configuration) {
    throw UnimplementedError('createClient() has not been implemented.');
  }

  Future<VaneResponse> execute(int handle, Map<String, Object?> request) {
    throw UnimplementedError('execute() has not been implemented.');
  }

  Future<void> closeClient(int handle) {
    throw UnimplementedError('closeClient() has not been implemented.');
  }

  Future<void> setCertificatePins(int handle, String host, List<String> pins) {
    throw UnimplementedError('setCertificatePins() has not been implemented.');
  }

  Future<int> createCancelToken() {
    throw UnimplementedError('createCancelToken() has not been implemented.');
  }

  Future<void> cancelToken(int id) {
    throw UnimplementedError('cancelToken() has not been implemented.');
  }

  Future<void> freeCancelToken(int id) {
    throw UnimplementedError('freeCancelToken() has not been implemented.');
  }

  Future<int> createProgress() {
    throw UnimplementedError('createProgress() has not been implemented.');
  }

  Future<VaneProgress> progressSnapshot(int id) {
    throw UnimplementedError('progressSnapshot() has not been implemented.');
  }

  Future<void> freeProgress(int id) {
    throw UnimplementedError('freeProgress() has not been implemented.');
  }
}
