import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:vane_flutter/vane_flutter.dart';
import 'package:vane_flutter/vane_flutter_ffi.dart';
import 'package:vane_flutter/vane_flutter_method_channel.dart';
import 'package:vane_flutter/vane_flutter_platform_interface.dart';

class MockVaneFlutterPlatform
    with MockPlatformInterfaceMixin
    implements VaneFlutterPlatform {
  int createdClients = 0;
  Map<String, Object?>? lastRequest;

  @override
  Future<int> createClient(Map<String, Object?> configuration) async {
    createdClients += 1;
    return 7;
  }

  @override
  Future<VaneResponse> execute(int handle, Map<String, Object?> request) async {
    lastRequest = request;
    return VaneResponse(
      statusCode: 200,
      headers: const <String, String>{'content-type': 'text/plain'},
      body: Uint8List.fromList('ok'.codeUnits),
      isSuccess: true,
      url: request['url'] as String,
    );
  }

  @override
  Future<void> closeClient(int handle) async {}
}

void main() {
  final initialPlatform = VaneFlutterPlatform.instance;

  test('$FfiVaneFlutter is the default instance', () {
    expect(initialPlatform, isInstanceOf<FfiVaneFlutter>());
  });

  test('$MethodChannelVaneFlutter remains available as a fallback', () {
    expect(MethodChannelVaneFlutter(), isA<MethodChannelVaneFlutter>());
  });

  test('client executes requests through the platform', () async {
    final fakePlatform = MockVaneFlutterPlatform();
    VaneFlutterPlatform.instance = fakePlatform;

    final client = VaneClient(
      requestInterceptors: [
        (request) => request.copyWith(
          headers: <String, String>{...request.headers, 'x-test': '1'},
        ),
      ],
    );
    final response = await client
        .request('/users')
        .queryParam('page', '1')
        .execute();

    expect(response.text, 'ok');
    expect(fakePlatform.createdClients, 1);
    expect(fakePlatform.lastRequest?['url'], '/users');
    expect(fakePlatform.lastRequest?['queryParams'], <String, String>{
      'page': '1',
    });
    expect(fakePlatform.lastRequest?['headers'], <String, String>{
      'x-test': '1',
    });

    VaneFlutterPlatform.instance = initialPlatform;
  });
}
