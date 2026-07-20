import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:brandmen_windows/device_http.dart';

void main() {
  test('health preserves playback position used by deployment verification',
      () async {
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 5011);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'playing': true,
          'positionMs': 4321,
          'activeDeploymentId': 'deployment-id',
          'playlistHash': 'playlist-hash',
          'currentFileSha256': 'file-hash',
        }))
        ..close();
    });

    final health = await DeviceHttp('127.0.0.1').health();

    expect(health, isNotNull);
    expect(health!['positionMs'], 4321);
    expect(health['activeDeploymentId'], 'deployment-id');
    expect(health['playlistHash'], 'playlist-hash');
    expect(health['currentFileSha256'], 'file-hash');
  });
}
