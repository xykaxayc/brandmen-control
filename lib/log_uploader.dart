import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/io_client.dart';
import 'logger.dart';
import 'updater.dart' show kAppVersion;

/// Служебный канал использует постоянный сертификат с SHA-256 pin и не зависит
/// от системного хранилища CA на Windows. Браузерная панель доступна без порта:
/// https://brandmen.xykaxayc.ru
const String kDefaultLogServerUrl = 'https://185.50.203.112';
const String _kLegacyLogServerUrl = 'https://77.246.102.205:8443';
const String kDefaultLogServerToken = '933897b46de4e38806e6d6669d768e9c';
const String _kLogServerCertSha256 =
    '66d54bc380ef63b293ba1a116d62899404400ec78ad98107c20e81823ec160f1';

/// Сохранённый адрес старого сервера переносится автоматически. Явный адрес
/// стороннего сервера оставляем без изменений.
String effectiveLogServerUrl(String? configured) {
  final value = (configured ?? '').trim().replaceAll(RegExp(r'/+$'), '');
  if (value.isEmpty || value == _kLegacyLogServerUrl) {
    return kDefaultLogServerUrl;
  }
  return value;
}

bool _trustedLogServerCertificate(
    X509Certificate cert, String host, int port, String targetHost) {
  return host == targetHost &&
      sha256.convert(cert.der).toString() == _kLogServerCertSha256;
}

/// Отправка лога на свой сервер.
///
/// Контракт сервера:
///   POST {baseUrl}/logs?site=<имя ПК>&version=<версия>&ts=<ISO время>
///   Authorization: Bearer <token>     (если токен задан)
///   Content-Type: text/plain; charset=utf-8
///   тело: текст лога
/// Ответ 2xx = успех; тело ответа (если есть) показывается пользователю.
class LogUploader {
  static Future<({bool ok, String message})> send({
    required String baseUrl,
    required String token,
    bool onlyRecent = false,
  }) async {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      return (ok: false, message: 'не указан адрес сервера логов (Настройки)');
    }

    final Uri uri;
    try {
      uri = Uri.parse('$base/logs').replace(queryParameters: {
        'site': Platform.localHostname,
        'version': kAppVersion,
        'ts': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      return (ok: false, message: 'неверный адрес сервера: $e');
    }

    final body = (onlyRecent ? AppLogger.lines : await _fullLog()).join('\n');

    // Сервер использует self-signed TLS, поэтому доверяем не любому
    // сертификату для этого IP, а только заранее проверенному SHA-256 pin.
    final targetHost = uri.host;
    final httpClient = HttpClient()
      ..badCertificateCallback = (cert, host, port) =>
          _trustedLogServerCertificate(cert, host, port, targetHost);
    final client = IOClient(httpClient);
    try {
      final resp = await client
          .post(
            uri,
            headers: {
              if (token.trim().isNotEmpty)
                'Authorization': 'Bearer ${token.trim()}',
              'Content-Type': 'text/plain; charset=utf-8',
            },
            body: utf8.encode(body),
          )
          .timeout(const Duration(seconds: 30));

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        AppLogger.log('Лог отправлен на сервер (HTTP ${resp.statusCode})');
        final msg = resp.body.trim();
        return (ok: true, message: msg.isNotEmpty ? msg : 'Лог отправлен');
      }
      AppLogger.log(
          'Отправка лога: HTTP ${resp.statusCode} ${resp.body.trim()}');
      return (ok: false, message: 'сервер вернул HTTP ${resp.statusCode}');
    } catch (e) {
      AppLogger.log('Отправка лога: ошибка $e');
      return (ok: false, message: '$e');
    } finally {
      client.close();
    }
  }

  /// Живой поток: дописать новые строки лога к серверному `_live.log`.
  /// Лёгкий — шлёт только переданные строки. Возвращает true при успехе.
  static Future<bool> sendLive({
    required String baseUrl,
    required String token,
    required List<String> lines,
  }) async {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty || lines.isEmpty) return false;
    final Uri uri;
    try {
      uri = Uri.parse('$base/live').replace(queryParameters: {
        'site': Platform.localHostname,
        'version': kAppVersion,
      });
    } catch (_) {
      return false;
    }
    final targetHost = uri.host;
    final httpClient = HttpClient()
      ..badCertificateCallback = (cert, host, port) =>
          _trustedLogServerCertificate(cert, host, port, targetHost);
    final client = IOClient(httpClient);
    try {
      final resp = await client
          .post(
            uri,
            headers: {
              if (token.trim().isNotEmpty)
                'Authorization': 'Bearer ${token.trim()}',
              'Content-Type': 'text/plain; charset=utf-8',
            },
            body: utf8.encode(lines.join('\n')),
          )
          .timeout(const Duration(seconds: 10));
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  static Future<List<String>> _fullLog() async {
    final path = AppLogger.logPath;
    if (path == null) return AppLogger.lines;
    await AppLogger.flush();
    try {
      final f = File(path);
      if (await f.exists()) return await f.readAsLines();
    } catch (_) {}
    return AppLogger.lines;
  }
}
