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
  /// [client] — переиспользуемый клиент: позволяет держать одно TCP-соединение
  /// (keep-alive) на всю сессию синка вместо нового на каждый файл. Если не
  /// передан, создаётся и закрывается внутри.
  Future<bool> uploadFile(
    File file, {
    void Function(int sent, int total)? onProgress,
    http.Client? client,
  }) async {
    final name = p.basename(file.path);
    final encodedName = Uri.encodeComponent(name);
    final size = await file.length();
    // Таймаут зависит от размера: фикс. 10 мин не хватало крупным роликам на
    // слабом WiFi. Закладываем ~0.5 МБ/с минимум + базовые 60с, потолок 60 мин.
    final uploadTimeout = Duration(
      seconds: (60 + size / (512 * 1024)).round().clamp(60, 3600),
    );
    return _retry(
      'HTTP upload $ip/$name',
      () async {
        final ownClient = client == null;
        final c = client ?? http.Client();
        try {
          final request = http.StreamedRequest(
              'POST', Uri.parse('$_base/upload/$encodedName'));
          request.contentLength = size;
          request.headers['Content-Type'] = 'application/octet-stream';

          // ВАЖНО: send() запускаем ДО подачи данных в sink. StreamedRequest
          // начинает читать тело только после send(); если сначала ждать
          // addStream/close, отправка зависает навсегда (таймаут не сработает).
          // addStream (в отличие от sink.add в listen) даёт backpressure —
          // файл не буферизуется целиком в память, а подаётся со скоростью сети.
          final responseFuture = c.send(request);

          int sent = 0;
          await request.sink.addStream(file.openRead().map((chunk) {
            sent += chunk.length;
            onProgress?.call(sent, size);
            return chunk;
          }));
          await request.sink.close();

          final response = await responseFuture.timeout(uploadTimeout);
          await response.stream.drain<void>();
          return response.statusCode == 200;
        } catch (e) {
          AppLogger.log('DeviceHttp.upload $name → $ip: $e');
          return false;
        } finally {
          if (ownClient) c.close();
        }
      },
      (ok) => ok,
    );
  }

  /// Отправляет APK на планшет по HTTP (`POST /api/update/install`). Плеер
  /// сам сохранит файл и покажет системное окно установки поверх плеера —
  /// без ADB и без ручного поиска файла в проводнике. Возвращает true, если
  /// планшет принял файл (HTTP 200).
  Future<bool> installApkHttp(File apk, {void Function(int sent, int total)? onProgress}) async {
    final size = await apk.length();
    if (size <= 0) return false;
    final uploadTimeout = Duration(
      seconds: (60 + size / (512 * 1024)).round().clamp(60, 1800),
    );
    final c = http.Client();
    try {
      final request = http.StreamedRequest(
          'POST', Uri.parse('$_base/api/update/install'));
      request.contentLength = size;
      request.headers['Content-Type'] = 'application/vnd.android.package-archive';
      final responseFuture = c.send(request);
      int sent = 0;
      await request.sink.addStream(apk.openRead().map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent, size);
        return chunk;
      }));
      await request.sink.close();
      final response = await responseFuture.timeout(uploadTimeout);
      await response.stream.drain<void>();
      AppLogger.log('installApkHttp $ip: HTTP ${response.statusCode}');
      return response.statusCode == 200;
    } catch (e) {
      AppLogger.log('installApkHttp $ip: $e');
      return false;
    } finally {
      c.close();
    }
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
    } catch (e) {
      AppLogger.log('DeviceHttp.controlStatus $ip: $e');
    }
    return null;
  }

  Future<bool> controlAction(String action, [Map<String, dynamic>? body]) async {
    final extra = (body != null && body.isNotEmpty) ? ' $body' : '';
    AppLogger.log('[КОМАНДА] $action → $ip$extra (POST /api/control/$action)');
    final sw = Stopwatch()..start();
    try {
      final r = await http
          .post(
            Uri.parse('$_base/api/control/$action'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body ?? {}),
          )
          .timeout(const Duration(seconds: 3));
      final ok = r.statusCode == 200;
      AppLogger.log('[КОМАНДА] $action → $ip: '
          '${ok ? "OK" : "ОШИБКА HTTP ${r.statusCode} ${r.body.trim()}"} '
          '(${sw.elapsedMilliseconds} мс)');
      return ok;
    } catch (e) {
      AppLogger.log('[КОМАНДА] $action → $ip: СБОЙ $e (${sw.elapsedMilliseconds} мс)');
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
    } catch (e) {
      AppLogger.log('DeviceHttp.controlNow $ip: $e');
    }
    return null;
  }

  /// Состояние планшета: версия, аптайм, свободное место, что играет.
  Future<Map<String, dynamic>?> health() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/health'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        return {
          'version': (j['version'] as String? ?? ''),
          'uptimeMs': (j['uptimeMs'] as num? ?? 0).toInt(),
          'freeMb': (j['freeMb'] as num? ?? 0).toInt(),
          'totalMb': (j['totalMb'] as num? ?? 0).toInt(),
          'playing': (j['playing'] as bool? ?? false),
          'index': (j['index'] as num? ?? -1).toInt(),
          'total': (j['total'] as num? ?? 0).toInt(),
          'current': (j['current'] as String? ?? ''),
          // Опциональные поля (новые версии плеера): без них null.
          'deviceOwner': j['deviceOwner'] as bool?,
          'battery': (j['battery'] as num?)?.toInt(),
        };
      }
    } catch (e) {
      AppLogger.log('DeviceHttp.health $ip: $e');
    }
    return null;
  }

  /// Скриншот экрана планшета (PNG) по HTTP — один запрос вместо трёх
  /// ADB-команд (rm/screencap/pull). Возвращает null, если плеер не
  /// поддерживает эндпоинт или недоступен — тогда вызывающий падает на ADB.
  Future<List<int>?> screenshotPng() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/api/control/screenshot'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) return r.bodyBytes;
    } catch (_) {
      // Молча: эндпоинт опциональный, опрашивается каждые 5 минут.
    }
    return null;
  }

  Future<bool> wake() => controlAction('wake');
  Future<bool> httpSleep() => controlAction('sleep');
  Future<bool> launch() => controlAction('launch');
  Future<bool> restart() => controlAction('restart');
  Future<bool> setVolumeHttp(int level) => controlAction('volume', {'level': level});
  Future<bool> setBrightnessHttp(int level) => controlAction('brightness', {'level': level});
}
