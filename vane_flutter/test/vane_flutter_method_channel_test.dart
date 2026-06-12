import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vane_flutter/vane_flutter_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelVaneFlutter();
  const channel = MethodChannel('vane_flutter');
  final calls = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
          calls.add(methodCall);
          switch (methodCall.method) {
            case 'createClient':
              return 42;
            case 'execute':
              return <String, Object?>{
                'statusCode': 200,
                'headers': <String, String>{'content-type': 'text/plain'},
                'body': Uint8List.fromList('ok'.codeUnits),
                'isSuccess': true,
                'url': 'https://example.com',
              };
            case 'closeClient':
              return null;
          }
          throw PlatformException(code: 'not-implemented');
        });
  });

  tearDown(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('createClient returns native handle', () async {
    expect(await platform.createClient(const <String, Object?>{}), 42);
    expect(calls.single.method, 'createClient');
  });

  test('execute decodes native response', () async {
    final response = await platform.execute(42, const <String, Object?>{
      'url': 'https://example.com',
      'method': 'GET',
    });

    expect(response.statusCode, 200);
    expect(response.text, 'ok');
    expect(calls.single.method, 'execute');
  });
}
