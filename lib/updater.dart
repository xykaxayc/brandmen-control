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

// /releases?per_page=1 возвращает последний релиз ВКЛЮЧАЯ pre-release,
// в отличие от /releases/latest который игнорирует pre-release.
const String _kReleasesUrl =
    'https://api.github.com/repos/$_kRepo/releases?per_page=1';

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
      final data = await _fetchLatestRelease();
      if (data == null) return null;

      final tag = (data['tag_name'] as String? ?? '').replaceFirst('v', '');
      final changelog = (data['body'] as String? ?? '').trim();
      if (!_isNewer(tag, kAppVersion)) return null;

      final assets = (data['assets'] as List?) ?? [];
      String? url;
      if (Platform.isWindows) {
        url = _findAssetUrl(assets, 'windows');
      } else if (Platform.isMacOS) {
        url = _findAssetUrl(assets, 'macos');
      }
      if (url == null) return null;

      return UpdateInfo(
          version: tag,
          tag: data['tag_name'] as String,
          downloadUrl: url,
          changelog: changelog);
    } catch (e) {
      AppLogger.log('Проверка обновлений: $e');
      return null;
    }
  }

  // ── Проверка обновления Android APK ────────────────────────────────────

  static Future<ApkUpdateInfo?> checkApkUpdate(
      {String currentApkVersion = '0.0.0'}) async {
    try {
      final data = await _fetchLatestRelease();
      if (data == null) return null;

      final tag = (data['tag_name'] as String? ?? '').replaceFirst('v', '');
      if (!_isNewer(tag, currentApkVersion)) return null;

      final assets = (data['assets'] as List?) ?? [];
      final url = _findAssetUrl(assets, 'brandmenads', ext: '.apk') ??
          _findAssetUrl(assets, '', ext: '.apk');
      if (url == null) return null;

      return ApkUpdateInfo(version: tag, downloadUrl: url);
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

  static Future<Map<String, dynamic>?> _fetchLatestRelease() async {
    final response = await http.get(
      Uri.parse(_kReleasesUrl),
      headers: {'User-Agent': 'BrandmenControl/$kAppVersion'},
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) return null;
    final list = jsonDecode(response.body);
    if (list is! List || list.isEmpty) return null;
    return list.first as Map<String, dynamic>;
  }

  static String? _findAssetUrl(List assets, String keyword,
      {String? ext}) {
    for (final a in assets) {
      final name = (a['name'] as String? ?? '').toLowerCase();
      final matchesKeyword =
          keyword.isEmpty || name.contains(keyword.toLowerCase());
      final matchesExt = ext == null || name.endsWith(ext.toLowerCase());
      if (matchesKeyword && matchesExt) {
        return a['browser_download_url'] as String?;
      }
    }
    return null;
  }

  static Future<bool> _downloadFile(
    String url,
    String destPath,
    void Function(double) onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(url));
    final response =
        await request.send().timeout(const Duration(minutes: 15));
    if (response.statusCode != 200) return false;

    final total = response.contentLength ?? 0;
    int received = 0;
    final sink = File(destPath).openWrite();
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress(received / total);
    }
    await sink.close();
    return true;
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

  static Future<void> _launchUpdateScript(
      String srcDir, String exeDir) async {
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
      await Process.start('cmd', ['/c', bat],
          mode: ProcessStartMode.detached);
    } else {
      final sh = p.join(tempDir, 'brandmen_apply_update.sh');
      final appBundle = p.normalize(p.join(exeDir, '..', '..', '..'));
      await File(sh).writeAsString('#!/bin/bash\n'
          'sleep 2\n'
          'cp -R "$srcDir/"* "$exeDir/"\n'
          'open "$appBundle"\n'
          'rm -- "\$0"\n'
          .replaceAll(r'$srcDir', srcDir)
          .replaceAll(r'$exeDir', exeDir)
          .replaceAll(r'$appBundle', appBundle));
      await Process.run('chmod', ['+x', sh]);
      await Process.start('bash', [sh], mode: ProcessStartMode.detached);
    }
    exit(0);
  }

  static bool _isNewer(String remote, String local) {
    if (remote.isEmpty || remote == '0.0.0') return false;
    if (local.isEmpty || local == '0.0.0') return false;
    List<int> parse(String v) =>
        v.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final r = parse(remote);
    final l = parse(local);
    for (int i = 0; i < 3; i++) {
      final rv = i < r.length ? r[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (rv > lv) return true;
      if (rv < lv) return false;
    }
    return false;
  }
}
