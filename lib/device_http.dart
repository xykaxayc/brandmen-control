import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'logger.dart';

const int kDeviceHttpPort = 5011;

/// HTTP-клиент для прямой передачи файлов на планшет (порт 5011).
/// Работает без ADB — только WiFi.
class DeviceHttp {
  final String ip;
  String get _base => 'http://$ip:$kDeviceHttpPort';

  DeviceHttp(this.ip);

  /// Проверяет, запущен ли HTTP-сервер на планшете.
  static Future<bool> isAvailable(String ip) async {
    try {
      final r = await http
          .get(Uri.parse('http://$ip:$kDeviceHttpPort/ping'))
          .timeout(const Duration(seconds: 2));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Список видеофайлов на планшете: { имя → размер_в_байтах }
  Future<Map<String, int>> listFiles() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/files'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return {};
      final list = jsonDecode(r.body) as List;
      return {for (final f in list) f['name'] as String: f['size'] as int};
    } catch (e) {
      AppLogger.log('DeviceHttp.listFiles $ip: $e');
      return {};
    }
  }

  /// Отправляет файл на планшет.
  /// onProgress(отправлено, всего) вызывается по мере отправки.
  Future<bool> uploadFile(
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final name = p.basename(file.path);
    final size = await file.length();
    try {
      final request =
          http.StreamedRequest('POST', Uri.parse('$_base/upload/$name'));
      request.headers['Content-Length'] = size.toString();
      request.headers['Content-Type'] = 'application/octet-stream';
      request.headers['Connection'] = 'close';

      int sent = 0;
      file.openRead().listen(
        (chunk) {
          request.sink.add(chunk);
          sent += chunk.length;
          onProgress?.call(sent, size);
        },
        onDone: request.sink.close,
        onError: (e) => request.sink.close(),
      );

      final response =
          await request.send().timeout(const Duration(minutes: 10));
      await response.stream.drain<void>();
      return response.statusCode == 200;
    } catch (e) {
      AppLogger.log('DeviceHttp.upload $name → $ip: $e');
      return false;
    }
  }

  /// Удаляет файл на планшете.
  Future<bool> deleteFile(String name) async {
    try {
      final r = await http
          .delete(Uri.parse('$_base/file/$name'))
          .timeout(const Duration(seconds: 10));
      return r.statusCode == 200;
    } catch (e) {
      AppLogger.log('DeviceHttp.delete $name on $ip: $e');
      return false;
    }
  }

  /// Скачивает файл с планшета на Mac/Windows.
  Future<File?> downloadFile(String name, String destPath) async {
    try {
      final request = http.Request('GET', Uri.parse('$_base/file/$name'));
      final response =
          await request.send().timeout(const Duration(minutes: 5));
      if (response.statusCode != 200) return null;

      final dest = File(destPath);
      final sink = dest.openWrite();
      await response.stream.pipe(sink);
      return dest;
    } catch (e) {
      AppLogger.log('DeviceHttp.download $name from $ip: $e');
      return null;
    }
  }
}
