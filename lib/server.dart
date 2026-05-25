import 'dart:io';
import 'logger.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:path/path.dart' as p;
import 'dart:convert';
import 'media_config.dart';

const int kServerPort = 5010;
const _videoExts = ['.mp4', '.mkv', '.mov', '.avi', '.wmv', '.flv', '.webm'];

class BrandmenServer {
  late HttpServer _server;

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
        final playlist = allFiles
            .where((f) => p.basename(f.path).toLowerCase() == 'playlist.m3u');

        final files = [...videos, ...playlist]
            .map((f) => {
                  "name": p.basename(f.path),
                  "size": f.lengthSync(),
                })
            .toList();
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
    AppLogger.log('Сервер запущен: ${_server.address.address}:${_server.port}');
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
    await _server.close();
  }
}
