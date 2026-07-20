import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'logger.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:path/path.dart' as p;
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:nsd/nsd.dart';
import 'media_config.dart';
import 'transcoder.dart';
import 'device_storage.dart';

const int kServerPort = 5010;

// Кэш md5 по ключу path+mtime+size. Ограничен по размеру, чтобы не расти вечно
// при долгой работе сервиса (раньше Map рос без удаления старых записей).
const int _hashCacheMax = 500;
final Map<String, String> _hashCache = {};

Future<String> _getFileHash(File file) async {
  try {
    final stat = await file.stat();
    final cacheKey =
        "${file.path}_${stat.modified.millisecondsSinceEpoch}_${stat.size}";
    final cached = _hashCache.remove(cacheKey);
    if (cached != null) {
      _hashCache[cacheKey] = cached; // освежаем порядок (LRU)
      return cached;
    }
    // В отдельном изоляте: md5 по гигабайтам видео в главном изоляте
    // подвешивал UI, пока планшет запрашивал манифест с холодным кэшем.
    final path = file.path;
    final h = await Isolate.run(
        () async => (await md5.bind(File(path).openRead()).first).toString());
    if (_hashCache.length >= _hashCacheMax) {
      _hashCache.remove(_hashCache.keys.first); // выбрасываем самый старый
    }
    _hashCache[cacheKey] = h;
    return h;
  } catch (e) {
    return "";
  }
}

class DeviceRegistration {
  final String ip;
  final String name;
  final String? deviceId;
  final String? apiToken;
  final bool isReconnect;
  DeviceRegistration({
    required this.ip,
    required this.name,
    this.deviceId,
    this.apiToken,
    this.isReconnect = false,
  });
}

class BrandmenServer {
  static BrandmenServer? instance;

  late HttpServer _server;
  Registration? _registration;

  final _registrationController =
      StreamController<DeviceRegistration>.broadcast();
  Stream<DeviceRegistration> get onDeviceRegistered =>
      _registrationController.stream;

  DateTime? _pairingUntil;

  bool get pairingActive =>
      _pairingUntil != null && DateTime.now().isBefore(_pairingUntil!);

  void startPairing({Duration duration = const Duration(seconds: 30)}) {
    _pairingUntil = DateTime.now().add(duration);
    AppLogger.log('Режим сопряжения активен на ${duration.inSeconds}с');
  }

  void stopPairing() => _pairingUntil = null;

  Future<void> start() async {
    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler((Request request) async {
      final path = request.url.path;
      final videoDir = MediaConfig.current ?? await MediaConfig.resolveDir();

      if (path == 'api/sync/manifest') {
        final dir = Directory(videoDir);
        if (!await dir.exists()) {
          return Response.ok('{"files":[]}',
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        final allFiles = dir.listSync().whereType<File>().toList();
        final allNames = allFiles.map((f) => p.basename(f.path)).toSet();
        final videos = allFiles.where((f) {
          final name = p.basename(f.path);
          if (!isVideoFile(name)) return false;
          // Исходник заменён сконвертированным mp4 — не отдаём его.
          return !Transcoder.hasMp4TwinIn(allNames, name);
        });
        final playlist = allFiles
            .where((f) => p.basename(f.path).toLowerCase() == 'playlist.m3u');

        // Хешируем параллельно, но батчами: на холодном кэше каждый хеш —
        // отдельный изолят, и без ограничения 30 файлов читали бы диск
        // одновременно.
        final entries = [...videos, ...playlist];
        final files = <Map<String, dynamic>>[];
        const hashBatch = 4;
        for (var i = 0; i < entries.length; i += hashBatch) {
          files.addAll(await Future.wait(
              entries.skip(i).take(hashBatch).map((f) async => {
                    "name": p.basename(f.path),
                    "size": await f.length(),
                    "md5": await _getFileHash(f),
                  })));
        }

        return Response.ok(jsonEncode({"files": files}),
            headers: {'content-type': 'application/json; charset=utf-8'});
      }

      if (path.startsWith('video/')) {
        final filename = Uri.decodeComponent(path.substring('video/'.length));
        if (filename.contains('..') || filename.contains('/')) {
          return Response.forbidden('forbidden');
        }
        final file = File(p.join(videoDir, filename));
        if (!await file.exists()) {
          return Response.notFound('not found');
        }
        final size = await file.length();
        return Response.ok(file.openRead(), headers: {
          'content-type': _mimeFor(filename),
          'content-length': size.toString(),
          'accept-ranges': 'bytes',
        });
      }

      if (path == 'api/ping') {
        return Response.ok('{"ok":true}',
            headers: {'content-type': 'application/json'});
      }

      if (request.method == 'POST' && path == 'api/register') {
        final connInfo =
            request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
        final clientIp = connInfo?.remoteAddress.address ?? '';
        String deviceName = clientIp;
        String? deviceId;
        String? apiToken;
        try {
          final body = await request.readAsString();
          if (body.isNotEmpty) {
            final json = jsonDecode(body) as Map<String, dynamic>;
            deviceName = (json['name'] as String?)?.trim().isNotEmpty == true
                ? json['name'] as String
                : clientIp;
            deviceId = (json['device_id'] as String?)?.trim();
            apiToken = (json['api_token'] as String?)?.trim();
          }
        } catch (_) {}
        final knownDevice =
            await DeviceStorage.authenticate(deviceId, apiToken);
        if (!pairingActive && !knownDevice) {
          return Response.forbidden('{"error":"pairing_off"}',
              headers: {'content-type': 'application/json'});
        }
        if (clientIp.isNotEmpty) {
          AppLogger.log(knownDevice
              ? 'Планшет восстановил связь: $clientIp ($deviceName)'
              : 'Устройство зарегистрировалось: $clientIp ($deviceName)');
          _registrationController.add(DeviceRegistration(
            ip: clientIp,
            name: deviceName,
            deviceId: deviceId,
            apiToken: apiToken,
            isReconnect: knownDevice,
          ));
        }
        return Response.ok(jsonEncode({'ok': true, 'reconnected': knownDevice}),
            headers: {'content-type': 'application/json'});
      }

      if (path == 'api/pairing-status') {
        return Response.ok(jsonEncode({'active': pairingActive}),
            headers: {'content-type': 'application/json'});
      }

      if (path.isEmpty) {
        return Response.ok(
            'Brandmen Control Server\nport: $kServerPort\nfolder: $videoDir',
            headers: {'content-type': 'text/plain; charset=utf-8'});
      }

      return Response.notFound('not found');
    });

    _server = await io.serve(handler, InternetAddress.anyIPv4, kServerPort);
    AppLogger.log('Сервер запущен: ${_server.address.address}:${_server.port}');

    try {
      _registration = await register(
        const Service(
            name: 'BrandmenServer', type: '_brandmen._tcp', port: kServerPort),
      );
      AppLogger.log('mDNS сервис зарегистрирован: _brandmen._tcp');
    } catch (e) {
      AppLogger.log('Ошибка регистрации mDNS: $e');
    }
  }

  static String _mimeFor(String name) {
    final ext = p.extension(name).toLowerCase();
    switch (ext) {
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.mkv':
        return 'video/x-matroska';
      case '.mov':
        return 'video/quicktime';
      case '.avi':
        return 'video/x-msvideo';
      case '.webm':
        return 'video/webm';
      case '.m3u':
      case '.m3u8':
        return 'audio/x-mpegurl';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> stop() async {
    if (_registration != null) {
      await unregister(_registration!);
    }
    await _server.close();
    await _registrationController.close();
  }
}
