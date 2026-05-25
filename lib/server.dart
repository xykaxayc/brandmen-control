import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:path/path.dart' as p;
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:nsd/nsd.dart';
import 'media_config.dart';

const int kServerPort = 5010;
const _videoExts = ['.mp4', '.mkv', '.mov', '.avi', '.wmv', '.flv', '.webm'];

final Map<String, String> _hashCache = {};

Future<String> _getFileHash(File file) async {
  try {
    final stat = await file.stat();
    final cacheKey = "${file.path}_${stat.modified.millisecondsSinceEpoch}_${stat.size}";
    if (_hashCache.containsKey(cacheKey)) {
      return _hashCache[cacheKey]!;
    }
    final hash = await md5.bind(file.openRead()).first;
    final h = hash.toString();
    _hashCache[cacheKey] = h;
    return h;
  } catch (e) {
    return "";
  }
}

class BrandmenServer {
  late HttpServer _server;
  Registration? _registration;

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
        final videos = allFiles.where(
            (f) => _videoExts.contains(p.extension(f.path).toLowerCase()));
        final playlist = allFiles.where(
            (f) => p.basename(f.path).toLowerCase() == 'playlist.m3u');

        final files = [];
        for (var f in [...videos, ...playlist]) {
          files.add({
            "name": p.basename(f.path),
            "size": f.lengthSync(),
            "md5": await _getFileHash(f),
          });
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

      if (path.isEmpty) {
        return Response.ok(
            'Brandmen Control Server\nport: $kServerPort\nfolder: $videoDir',
            headers: {'content-type': 'text/plain; charset=utf-8'});
      }

      return Response.notFound('not found');
    });

    _server = await io.serve(handler, InternetAddress.anyIPv4, kServerPort);
    print('Сервер запущен: ${_server.address.address}:${_server.port}');

    try {
      _registration = await register(
        Service(name: 'BrandmenServer', type: '_brandmen._tcp', port: kServerPort),
      );
      print('mDNS сервис зарегистрирован: _brandmen._tcp');
    } catch (e) {
      print('Ошибка регистрации mDNS: $e');
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
  }
}
