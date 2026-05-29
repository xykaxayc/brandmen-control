import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'logger.dart';

// Версия встраивается CI: --dart-define=APP_VERSION=0.42.0
// При локальной сборке = '0.0.0' (обновления не будут предлагаться)
const String kAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');

const String _kRepo = 'xykaxayc/brandmen-control';

// Берём несколько последних релизов (включая pre-release). Каждый workflow
// (Win/Mac/APK) собирается по своему path-фильтру, поэтому самый свежий релиз
// может не содержать нужный ассет — ищем новейший релиз, где он ЕСТЬ.
const String _kReleasesUrl =
    'https://api.github.com/repos/$_kRepo/releases?per_page=15';

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

class AppUpdater {
  // ── Проверка обновления десктоп-приложения ──────────────────────────────

  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      if (!Platform.isWindows && !Platform.isMacOS) return null;
      if (kAppVersion == '0.0.0') return null;
      final keyword = Platform.isWindows ? 'windows' : 'macos';
      final r = await _findNewestRelease(
        currentVersion: kAppVersion,
        matches: (name) => name.contains(keyword) && name.endsWith('.zip'),
      );
      if (r == null) return null;
      return UpdateInfo(
          version: r['version']!,
          tag: r['tag']!,
          downloadUrl: r['url']!,
          changelog: r['changelog']!);
    } catch (e) {
      AppLogger.log('Проверка обновлений: $e');
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
      final ok = await _downloadFile(info.downloadUrl, apkPath, onProgress);
      return ok ? File(apkPath) : null;
    } catch (e) {
      AppLogger.log('Скачивание APK: $e');
      return null;
    }
  }

  // ── Скачать и применить обновление десктоп-приложения ───────────────────

  static Future<bool> downloadAndApply(
    UpdateInfo info,
    void Function(double progress, String status) onProgress,
  ) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final zipPath = p.join(tempDir.path, 'brandmen_update.zip');
      final updateDir = p.join(tempDir.path, 'brandmen_update_new');

      onProgress(0.0, 'Скачиваю ${info.version}...');
      final ok = await _downloadFile(
        info.downloadUrl,
        zipPath,
        (p) => onProgress(p * 0.85, 'Скачиваю... ${(p * 100).round()}%'),
      );
      if (!ok) return false;

      onProgress(0.87, 'Распаковываю...');
      if (!await _extract(zipPath, updateDir)) return false;
      await File(zipPath).delete().catchError((_) => File(zipPath));

      onProgress(0.97, 'Применяю обновление...');
      final exeDir = p.dirname(Platform.resolvedExecutable);
      await _launchUpdateScript(updateDir, exeDir);
      return true;
    } catch (e) {
      AppLogger.log('Ошибка обновления: $e');
      return false;
    }
  }

  // ── Внутренние хелперы ──────────────────────────────────────────────────

  static Future<List<dynamic>> _fetchReleases() async {
    final response = await http.get(
      Uri.parse(
          '$_kReleasesUrl&_=${DateTime.now().millisecondsSinceEpoch}'),
      headers: {
        'Accept': 'application/vnd.github+json',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
        'User-Agent': 'BrandmenControl/$kAppVersion',
      },
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      AppLogger.log('GitHub releases: HTTP ${response.statusCode}');
      return [];
    }
    final list = jsonDecode(response.body);
    if (list is! List) return [];
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
    for (final rel in releases) {
      if (rel is! Map) continue;
      final rawTag = rel['tag_name'] as String? ?? '';
      final version = rawTag.replaceFirst('v', '');
      if (!_isNewer(version, currentVersion)) continue;
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

  static Future<bool> _downloadFile(
    String url,
    String destPath,
    void Function(double) onProgress,
  ) async {
    // dart:io HttpClient следует 302-редиректам (GitHub releases → CDN)
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.followRedirects = true;
      req.maxRedirects = 5;
      final response = await req.close().timeout(const Duration(minutes: 15));
      if (response.statusCode != 200) return false;

      final total = response.contentLength;
      int received = 0;
      final destFile = File(destPath);
      // getTemporaryDirectory() возвращает путь, но сама папка может не существовать
      await destFile.parent.create(recursive: true);
      final sink = destFile.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.close();
      return true;
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
