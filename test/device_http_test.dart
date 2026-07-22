import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:brandmen_windows/device_http.dart';
import 'package:brandmen_windows/adb_manager.dart';

void main() {
  test('health preserves playback position used by deployment verification',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 5011);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'playing': true,
          'playbackEnabled': false,
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
    expect(health['playbackEnabled'], isFalse);
    expect(health['activeDeploymentId'], 'deployment-id');
    expect(health['playlistHash'], 'playlist-hash');
    expect(health['currentFileSha256'], 'file-hash');
  });

  test('desired-state never falls back to legacy without a pairing key',
      () async {
    final requestedPaths = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 5011);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      requestedPaths.add(request.uri.path);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(request.uri.path == '/ping'
            ? '{"ok":true}'
            : '{"protocol_version":2,"auth_required":true}')
        ..close();
    });

    final result = await AdbManager().syncDeviceDirect(
      '127.0.0.1',
      '/folder-that-must-not-be-read',
      requireDeploymentV2: true,
    );

    expect(result.success, isFalse);
    expect(result.transport, 'Deployment v2');
    expect(result.error, contains('сопряжение'));
    expect(requestedPaths, ['/ping', '/api/v2/capabilities']);
  });
}
