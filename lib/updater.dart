import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'logger.dart';

// Версия встраивается CI: --dart-define=APP_VERSION=0.42.0
// При локальной сборке = '0.0.0' (обновления не будут предлагаться)
const String kAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');

const String _kRepo = 'xykaxayc/brandmen-control';

// Страница релизов — показываем её пользователю, когда автообновление не удалось,
// чтобы скачать сборку вручную.
const String kReleasesPageUrl = 'https://github.com/$_kRepo/releases/latest';

// Берём несколько последних релизов (включая pre-release). Каждый workflow
// (Win/Mac/APK) собирается по своему path-фильтру, поэтому самый свежий релиз
// может не содержать нужный ассет — ищем новейший релиз, где он ЕСТЬ.
const String _kReleasesUrl =
    'https://api.github.com/repos/$_kRepo/releases?per_page=15';

// На части машин (антивирус/корпоративный прокси перехватывает HTTPS, либо в
// хранилище Dart нет нужного корня) проверка сертификата GitHub падает с
// CERTIFICATE_VERIFY_FAILED, и обновления не работают. Доверяем сертификату
// ТОЛЬКО для доменов GitHub — глобально проверку не отключаем.
bool _trustGithub(X509Certificate cert, String host, int port) {
  final ok = host == 'github.com' ||
      host.endsWith('.github.com') ||
      host.endsWith('.githubusercontent.com');
  if (ok) {
    AppLogger.log('[UPD] принят неподтверждённый TLS-сертификат для $host '
        '(вероятно перехват антивирусом/прокси или корень не в Dart)');
  }
  return ok;
}

HttpClient _githubHttpClient() =>
    HttpClient()..badCertificateCallback = _trustGithub;

http.Client _githubClient() => IOClient(_githubHttpClient());

class UpdateInfo {
  final String version;
  final String tag;
  final String downloadUrl;
  final String changelog;
  UpdateInfo({
    required this.version,
    required this.tag,
    required this.downloadUrl,
    required this.changelog,
  });
}

class ApkUpdateInfo {
  final String version;
  final String downloadUrl;
  ApkUpdateInfo({required this.version, required this.downloadUrl});
}

/// Позволяет отменить идущую загрузку из UI (крестик в диалоге).
/// Держит ссылку на активный HttpClient и принудительно его закрывает —
/// это рвёт «зависшее» соединение, а не просто выставляет флаг.
class CancelToken {
  bool _cancelled = false;
  HttpClient? _client;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    try {
      _client?.close(force: true);
    } catch (_) {}
  }

  void _bind(HttpClient c) {
    _client = c;
    if (_cancelled) {
      try {
        c.close(force: true);
      } catch (_) {}
    }
  }
}

class AppUpdater {
  /// Текст последней ошибки загрузки/применения — UI показывает его пользователю.
  static String? lastError;

  // ── Проверка обновления десктоп-приложения ──────────────────────────────

  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      AppLogger.log('[UPD] checkForUpdate: текущая=$kAppVersion '
          'platform=${Platform.operatingSystem}');
      if (!Platform.isWindows && !Platform.isMacOS) {
        AppLogger.log('[UPD] не Windows/macOS — пропуск');
        return null;
      }
      if (kAppVersion == '0.0.0') {
        AppLogger.log('[UPD] версия 0.0.0 (локальная сборка) — обновления отключены');
        return null;
      }
      final keyword = Platform.isWindows ? 'windows' : 'macos';
      final r = await _findNewestRelease(
        currentVersion: kAppVersion,
        matches: (name) => name.contains(keyword) && name.endsWith('.zip'),
      );
      if (r == null) {
        AppLogger.log('[UPD] подходящего обновления не найдено → "последняя версия"');
        return null;
      }
      AppLogger.log('[UPD] НАЙДЕНО обновление: ${r['version']} (${r['url']})');
      return UpdateInfo(
          version: r['version']!,
          tag: r['tag']!,
          downloadUrl: r['url']!,
          changelog: r['changelog']!);
    } catch (e, st) {
      AppLogger.log('[UPD] ОШИБКА checkForUpdate: $e\n$st');
      return null;
    }
  }

  // ── Проверка обновления Android APK ────────────────────────────────────

  static Future<ApkUpdateInfo?> checkApkUpdate(
      {String currentApkVersion = '0.0.0'}) async {
    try {
      final r = await _findNewestRelease(
        currentVersion: currentApkVersion,
        matches: (name) => name.endsWith('.apk'),
      );
      if (r == null) return null;
      return ApkUpdateInfo(version: r['version']!, downloadUrl: r['url']!);
    } catch (e) {
      AppLogger.log('Проверка APK обновления: $e');
      return null;
    }
  }

  // ── Скачать APK на диск ─────────────────────────────────────────────────

  static Future<File?> downloadApk(
    ApkUpdateInfo info,
    void Function(double progress) onProgress,
  ) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final apkPath = p.join(tempDir.path, 'BrandmenAds-update.apk');
      final ok = await _downloadFile(
        info.downloadUrl,
        apkPath,
        (prog, _) => onProgress(prog < 0 ? 0 : prog),
      );
      return ok ? File(apkPath) : null;
    } catch (e) {
      AppLogger.log('Скачивание APK: $e');
      return null;
    }
  }

  // ── Скачать и применить обновление десктоп-приложения ───────────────────

  static Future<bool> downloadAndApply(
    UpdateInfo info,
    void Function(double progress, String status) onProgress, {
    CancelToken? cancel,
  }) async {
    lastError = null;
    try {
      final tempDir = await getTemporaryDirectory();
      final zipPath = p.join(tempDir.path, 'brandmen_update.zip');
      final updateDir = p.join(tempDir.path, 'brandmen_update_new');

      onProgress(0.0, 'Скачиваю ${info.version}...');
      final ok = await _downloadFile(
        info.downloadUrl,
        zipPath,
        (prog, bytes) {
          // content-length неизвестен → prog < 0: показываем мегабайты и
          // бесконечную полосу, иначе процент.
          if (prog < 0) {
            onProgress(-1,
                'Скачиваю... ${(bytes / 1024 / 1024).toStringAsFixed(1)} МБ');
          } else {
            onProgress(prog * 0.85, 'Скачиваю... ${(prog * 100).round()}%');
          }
        },
        cancel: cancel,
      );
      if (cancel?.isCancelled ?? false) return false;
      if (!ok) return false;

      onProgress(0.87, 'Распаковываю...');
      if (!await _extract(zipPath, updateDir)) {
        lastError ??= 'не удалось распаковать архив';
        return false;
      }
      await File(zipPath).delete().catchError((_) => File(zipPath));
      if (cancel?.isCancelled ?? false) return false;

      onProgress(0.97, 'Применяю обновление...');
      final exeDir = p.dirname(Platform.resolvedExecutable);
      await _launchUpdateScript(updateDir, exeDir);
      return true;
    } catch (e) {
      AppLogger.log('Ошибка обновления: $e');
      lastError = '$e';
      return false;
    }
  }

  // ── Внутренние хелперы ──────────────────────────────────────────────────

  static Future<List<dynamic>> _fetchReleases() async {
    final client = _githubClient();
    final http.Response response;
    try {
      response = await client.get(
        Uri.parse(
            '$_kReleasesUrl&_=${DateTime.now().millisecondsSinceEpoch}'),
        headers: {
          'Accept': 'application/vnd.github+json',
          'Cache-Control': 'no-cache',
          'Pragma': 'no-cache',
          'User-Agent': 'BrandmenControl/$kAppVersion',
        },
      ).timeout(const Duration(seconds: 10));
    } finally {
      client.close();
    }

    AppLogger.log('[UPD] GET $_kReleasesUrl → HTTP ${response.statusCode}, '
        '${response.body.length} байт');
    if (response.statusCode != 200) {
      AppLogger.log('[UPD] не 200 — тело: '
          '${response.body.substring(0, response.body.length.clamp(0, 300))}');
      return [];
    }
    final list = jsonDecode(response.body);
    if (list is! List) {
      AppLogger.log('[UPD] ответ не является списком релизов');
      return [];
    }
    final tags = list
        .map((r) => (r as Map?)?['tag_name'] ?? '?')
        .toList()
        .join(', ');
    AppLogger.log('[UPD] получено релизов: ${list.length} → $tags');
    list.sort((a, b) {
      final av = ((a as Map?)?['tag_name'] as String? ?? '')
          .replaceFirst('v', '');
      final bv = ((b as Map?)?['tag_name'] as String? ?? '')
          .replaceFirst('v', '');
      return _compareVersions(bv, av);
    });
    return list;
  }

  // Ищет новейший релиз (свежее currentVersion), содержащий подходящий ассет.
  // Релизы из API идут от новых к старым, поэтому первое совпадение — нужное.
  static Future<Map<String, String>?> _findNewestRelease({
    required String currentVersion,
    required bool Function(String nameLower) matches,
  }) async {
    final releases = await _fetchReleases();
    AppLogger.log('[UPD] ищу релиз новее $currentVersion с нужным ассетом '
        '(всего ${releases.length})');
    for (final rel in releases) {
      if (rel is! Map) continue;
      final rawTag = rel['tag_name'] as String? ?? '';
      final version = rawTag.replaceFirst('v', '');
      final assetNames = ((rel['assets'] as List?) ?? [])
          .map((a) => (a['name'] as String? ?? '').toLowerCase())
          .toList();
      final newer = _isNewer(version, currentVersion);
      final hasAsset = assetNames.any(matches);
      AppLogger.log('[UPD]   $rawTag: новее=$newer ассеты=$assetNames '
          'подходит=$hasAsset');
      if (!newer) continue;
      final assets = (rel['assets'] as List?) ?? [];
      for (final a in assets) {
        final name = (a['name'] as String? ?? '').toLowerCase();
        if (matches(name)) {
          final url = a['browser_download_url'] as String?;
          if (url != null) {
            return {
              'tag': rawTag,
              'version': version,
              'url': url,
              'changelog': (rel['body'] as String? ?? '').trim(),
            };
          }
        }
      }
    }
    return null;
  }

  // onProgress(progress, receivedBytes): progress в [0..1], либо -1 если сервер
  // не прислал content-length (тогда ориентируемся на receivedBytes).
  static Future<bool> _downloadFile(
    String url,
    String destPath,
    void Function(double progress, int receivedBytes) onProgress, {
    CancelToken? cancel,
  }) async {
    // dart:io HttpClient следует 302-редиректам (GitHub releases → CDN).
    // Тот же обход проверки сертификата для доменов GitHub, что и при проверке.
    final client = _githubHttpClient();
    cancel?._bind(client);
    final destFile = File(destPath);
    IOSink? sink;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.followRedirects = true;
      req.maxRedirects = 5;
      final response = await req.close().timeout(const Duration(minutes: 15));
      if (response.statusCode != 200) {
        AppLogger.log('[UPD] загрузка: HTTP ${response.statusCode}');
        lastError = 'сервер вернул HTTP ${response.statusCode}';
        return false;
      }

      final total = response.contentLength;
      int received = 0;
      // getTemporaryDirectory() возвращает путь, но сама папка может не существовать
      await destFile.parent.create(recursive: true);
      final out = destFile.openWrite();
      sink = out;
      await for (final chunk in response) {
        if (cancel?.isCancelled ?? false) {
          await out.close();
          sink = null;
          await destFile.delete().catchError((_) => destFile);
          return false;
        }
        out.add(chunk);
        received += chunk.length;
        onProgress(total > 0 ? received / total : -1, received);
      }
      await out.close();
      sink = null;
      return true;
    } catch (e) {
      // Принудительное закрытие клиента при отмене кидает исключение — это норма.
      if (cancel?.isCancelled ?? false) return false;
      AppLogger.log('[UPD] ошибка загрузки: $e');
      lastError = '$e';
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await destFile.exists()) await destFile.delete();
      } catch (_) {}
      return false;
    } finally {
      client.close();
    }
  }

  static Future<bool> _extract(String zipPath, String destDir) async {
    if (Platform.isWindows) {
      final r = await Process.run('powershell', [
        '-Command',
        'Expand-Archive -Path "${zipPath.replaceAll("'", "''")}" '
            '-DestinationPath "${destDir.replaceAll("'", "''")}" -Force',
      ]);
      return r.exitCode == 0;
    } else {
      await Directory(destDir).create(recursive: true);
      final r = await Process.run('unzip', ['-o', zipPath, '-d', destDir]);
      return r.exitCode == 0;
    }
  }

  static Future<void> _launchUpdateScript(String srcDir, String exeDir) async {
    final tempDir = Directory.systemTemp.path;
    if (Platform.isWindows) {
      final bat = p.join(tempDir, 'brandmen_apply_update.bat');
      final exePath = p.join(exeDir, 'brandmen_windows.exe');
      await File(bat).writeAsString('@echo off\r\n'
              'timeout /t 2 /nobreak >nul\r\n'
              'xcopy /s /e /y "$srcDir\\*" "$exeDir\\" >nul\r\n'
              'start "" "$exePath"\r\n'
              '(goto) 2>nul & del "%~f0"\r\n'
          .replaceAll(r'$srcDir', srcDir)
          .replaceAll(r'$exeDir', exeDir)
          .replaceAll(r'$exePath', exePath));
      await Process.start('cmd', ['/c', bat], mode: ProcessStartMode.detached);
    } else {
      final sh = p.join(tempDir, 'brandmen_apply_update.sh');
      final log = p.join(tempDir, 'brandmen_update.log');
      final appBundle = p.normalize(p.join(exeDir, '..', '..'));
      final appParent = p.dirname(appBundle);

      // Не полагаемся на совпадение имени — ищем любой .app в srcDir
      final script = '''#!/bin/bash
LOG="$log"
exec > "\$LOG" 2>&1
echo "=== Brandmen update \$(date) ==="
echo "srcDir:    $srcDir"
echo "appBundle: $appBundle"
echo "appParent: $appParent"

sleep 2

# Найти .app в распакованной папке
SRC_APP=\$(find "$srcDir" -maxdepth 2 -name "*.app" -type d | head -1)
if [ -z "\$SRC_APP" ]; then
  echo "ERROR: .app не найден в $srcDir, содержимое:"
  ls -la "$srcDir" || true
  exit 1
fi
echo "Найдено: \$SRC_APP"

# Сначала копируем рядом под временным именем, потом атомарно меняем
DEST_APP="$appParent/\$(basename "\$SRC_APP")"
TMP_APP="\${DEST_APP}.update_tmp"

echo "Копирую в \$TMP_APP ..."
rm -rf "\$TMP_APP"
cp -R "\$SRC_APP" "\$TMP_APP"
if [ \$? -ne 0 ]; then
  echo "ERROR: cp -R не удалось"
  rm -rf "\$TMP_APP"
  exit 1
fi

# Снимаем quarantine
xattr -dr com.apple.quarantine "\$TMP_APP" 2>/dev/null || true

# Заменяем старый .app
echo "Заменяю $appBundle ..."
rm -rf "$appBundle"
mv "\$TMP_APP" "\$DEST_APP"

echo "Запускаю \$DEST_APP ..."
open "\$DEST_APP"
echo "Готово"
rm -- "\$0"
''';

      await File(sh).writeAsString(script);
      await Process.run('chmod', ['+x', sh]);
      await Process.start('bash', [sh], mode: ProcessStartMode.detached);
    }
    exit(0);
  }

  static bool _isNewer(String remote, String local) {
    return _compareVersions(remote, local) > 0;
  }

  static int _compareVersions(String remote, String local) {
    if (remote.isEmpty || remote == '0.0.0') return 0;
    if (local.isEmpty) return 0;
    List<int> parse(String v) =>
        v.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final r = parse(remote);
    final l = parse(local);
    for (int i = 0; i < 3; i++) {
      final rv = i < r.length ? r[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (rv > lv) return 1;
      if (rv < lv) return -1;
    }
    return 0;
  }
}
