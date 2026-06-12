import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vane_flutter/vane_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('client can be configured', (tester) async {
    final client = VaneClient(
      configuration: const VaneConfiguration(
        cookiesEnabled: true,
        connectionPoolEnabled: true,
      ),
    );

    await client.close();
  });
}
