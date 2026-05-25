import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'logger.dart';
import 'server.dart';

const int kDiscoveryPort = 5012;

// Периодически шлёт UDP broadcast, чтобы планшеты находили этот компьютер автоматически.
class DiscoveryBeacon {
  static const _interval = Duration(seconds: 3);

  RawDatagramSocket? _socket;
  Timer? _timer;

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket!.broadcastEnabled = true;
      _send();
      _timer = Timer.periodic(_interval, (_) => _send());
      AppLogger.log('Discovery beacon запущен (UDP broadcast :$kDiscoveryPort)');
    } catch (e) {
      AppLogger.log('Discovery beacon ошибка: $e');
    }
  }

  void _send() {
    final msg = utf8.encode(
      jsonEncode({'service': 'brandmen-control', 'port': kServerPort}),
    );
    try {
      _socket?.send(msg, InternetAddress('255.255.255.255'), kDiscoveryPort);
    } catch (_) {}
  }

  void stop() {
    _timer?.cancel();
    _socket?.close();
    _socket = null;
  }
}
