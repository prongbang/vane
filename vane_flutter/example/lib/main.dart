import 'package:flutter/material.dart';
import 'package:vane_flutter/vane_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _client = VaneClient(
    configuration: const VaneConfiguration(
      cookiesEnabled: true,
      connectionPoolEnabled: true,
      retryMaxAttempts: 2,
    ),
  );
  String _result = 'Ready';

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _runRequest() async {
    setState(() {
      _result = 'Loading...';
    });

    try {
      final response = await _client
          .request('https://cloudflare-quic.com', method: 'GET')
          .responseString();
      setState(() {
        _result = response.isEmpty ? 'HTTP/3 response received' : response;
      });
    } catch (error) {
      setState(() {
        _result = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Vane Flutter')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton(
                onPressed: _runRequest,
                child: const Text('Run HTTP/3 request'),
              ),
              const SizedBox(height: 16),
              Text(_result),
            ],
          ),
        ),
      ),
    );
  }
}
