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

  static Future<T> _retry<T>(
    String label,
    Future<T> Function() action,
    bool Function(T value) isSuccess, {
    int attempts = 3,
    Duration delay = const Duration(milliseconds: 500),
  }) async {
    late T last;
    for (int i = 1; i <= attempts; i++) {
      last = await action();
      if (isSuccess(last) || i == attempts) return last;
      AppLogger.log('$label: попытка $i/$attempts не удалась, повтор...');
      await Future.delayed(delay * i);
    }
    return last;
  }

  /// Проверяет, запущен ли HTTP-сервер на планшете.
  static Future<bool> isAvailable(String ip) async {
    return _retry(
      'HTTP ping $ip',
      () async {
        try {
          final r = await http
              .get(Uri.parse('http://$ip:$kDeviceHttpPort/ping'))
              .timeout(const Duration(seconds: 2));
          return r.statusCode == 200;
        } catch (_) {
          return false;
        }
      },
      (ok) => ok,
      attempts: 2,
    );
  }

  /// Список видеофайлов на планшете: { имя → размер_в_байтах }
  Future<Map<String, int>?> listFiles() async {
    return _retry<Map<String, int>?>(
      'HTTP listFiles $ip',
      () async {
        try {
          final r = await http
              .get(Uri.parse('$_base/files'))
              .timeout(const Duration(seconds: 5));
          if (r.statusCode != 200) return null;
          final list = jsonDecode(r.body) as List;
          return {for (final f in list) f['name'] as String: f['size'] as int};
        } catch (e) {
          AppLogger.log('DeviceHttp.listFiles $ip: $e');
          return null;
        }
      },
      (files) => files != null,
    );
  }

  /// Отправляет файл на планшет.
  /// onProgress(отправлено, всего) вызывается по мере отправки.
  Future<bool> uploadFile(
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final name = p.basename(file.path);
    final encodedName = Uri.encodeComponent(name);
    final size = await file.length();
    return _retry(
      'HTTP upload $ip/$name',
      () async {
        try {
          final request = http.StreamedRequest(
              'POST', Uri.parse('$_base/upload/$encodedName'));
          request.contentLength = size;
          request.headers['Content-Type'] = 'application/octet-stream';
          request.headers['Connection'] = 'close';

          // ВАЖНО: send() запускаем ДО подачи данных в sink. StreamedRequest
          // начинает читать тело только после send(); если сначала ждать
          // addStream/close, отправка зависает навсегда (таймаут не сработает).
          final responseFuture = request.send();

          int sent = 0;
          file.openRead().listen(
            (chunk) {
              sent += chunk.length;
              onProgress?.call(sent, size);
              request.sink.add(chunk);
            },
            onDone: () => request.sink.close(),
            onError: (Object e) {
              request.sink.addError(e);
              request.sink.close();
            },
            cancelOnError: true,
          );

          final response =
              await responseFuture.timeout(const Duration(minutes: 10));
          await response.stream.drain<void>();
          return response.statusCode == 200;
        } catch (e) {
          AppLogger.log('DeviceHttp.upload $name → $ip: $e');
          return false;
        }
      },
      (ok) => ok,
    );
  }

  /// Удаляет файл на планшете.
  Future<bool> deleteFile(String name) async {
    return _retry(
      'HTTP delete $ip/$name',
      () async {
        try {
          final encodedName = Uri.encodeComponent(name);
          final r = await http
              .delete(Uri.parse('$_base/file/$encodedName'))
              .timeout(const Duration(seconds: 10));
          return r.statusCode == 200;
        } catch (e) {
          AppLogger.log('DeviceHttp.delete $name on $ip: $e');
          return false;
        }
      },
      (ok) => ok,
      attempts: 2,
    );
  }

  /// Скачивает файл с планшета на Mac/Windows.
  Future<File?> downloadFile(String name, String destPath) async {
    try {
      final encodedName = Uri.encodeComponent(name);
      final request =
          http.Request('GET', Uri.parse('$_base/file/$encodedName'));
      final response = await request.send().timeout(const Duration(minutes: 5));
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

  // ---- Remote control ----

  /// Читает текущий статус планшета: volume, volumeMax, brightness.
  Future<Map<String, int>?> controlStatus() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/api/control/status'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        return {
          'volume': (j['volume'] as num).toInt(),
          'volumeMax': (j['volumeMax'] as num? ?? 15).toInt(),
          'brightness': (j['brightness'] as num).toInt(),
        };
      }
    } catch (_) {}
    return null;
  }

  Future<bool> controlAction(String action, [Map<String, dynamic>? body]) async {
    try {
      final r = await http
          .post(
            Uri.parse('$_base/api/control/$action'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body ?? {}),
          )
          .timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Читает текущий проигрываемый ролик: index, total, name, playing.
  Future<Map<String, dynamic>?> controlNow() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/api/control/now'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        return {
          'index': (j['index'] as num? ?? -1).toInt(),
          'total': (j['total'] as num? ?? 0).toInt(),
          'name': (j['name'] as String? ?? ''),
          'playing': (j['playing'] as bool? ?? false),
        };
      }
    } catch (_) {}
    return null;
  }

  Future<bool> wake() => controlAction('wake');
  Future<bool> httpSleep() => controlAction('sleep');
  Future<bool> launch() => controlAction('launch');
  Future<bool> restart() => controlAction('restart');
  Future<bool> setVolumeHttp(int level) => controlAction('volume', {'level': level});
  Future<bool> setBrightnessHttp(int level) => controlAction('brightness', {'level': level});
}
