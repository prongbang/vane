import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'vane_flutter.dart';
import 'vane_flutter_method_channel.dart';

abstract class VaneFlutterPlatform extends PlatformInterface {
  VaneFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static VaneFlutterPlatform _instance = MethodChannelVaneFlutter();

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
}
