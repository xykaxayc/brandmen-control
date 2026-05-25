import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'logger.dart';

const String kAppVersion = '1.0.0';
const String _kRepo = 'xykaxayc/brandmen-control';
const String _kApiUrl = 'https://api.github.com/repos/$_kRepo/releases/latest';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String changelog;
  UpdateInfo({required this.version, required this.downloadUrl, required this.changelog});
}

class AppUpdater {
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final response = await http.get(
        Uri.parse(_kApiUrl),
        headers: {'User-Agent': 'BrandmenControl/$kAppVersion'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String? ?? '').replaceFirst('v', '');
      final changelog = (data['body'] as String? ?? '').trim();
      if (!_isNewer(tag, kAppVersion)) return null;

      final assets = (data['assets'] as List?) ?? [];
      String? url;
      if (Platform.isWindows) {
        final a = assets.cast<Map>().where((a) =>
            (a['name'] as String).toLowerCase().contains('windows')).firstOrNull;
        url = a?['browser_download_url'] as String?;
      } else if (Platform.isMacOS) {
        final a = assets.cast<Map>().where((a) =>
            (a['name'] as String).toLowerCase().contains('macos')).firstOrNull;
        url = a?['browser_download_url'] as String?;
      }
      if (url == null) return null;

      return UpdateInfo(version: tag, downloadUrl: url, changelog: changelog);
    } catch (e) {
      AppLogger.log('Проверка обновлений: $e');
      return null;
    }
  }

  // Скачивает архив, распаковывает рядом с exe и перезапускает приложение.
  // onProgress: 0.0 .. 1.0
  static Future<bool> downloadAndApply(
    UpdateInfo info,
    void Function(double progress, String status) onProgress,
  ) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final zipPath = p.join(tempDir.path, 'brandmen_update.zip');
      final updateDir = p.join(tempDir.path, 'brandmen_update_new');

      // 1. Скачиваем
      onProgress(0.0, 'Скачиваю ${info.version}...');
      final request = http.Request('GET', Uri.parse(info.downloadUrl));
      final response = await request.send().timeout(const Duration(minutes: 10));
      if (response.statusCode != 200) return false;

      final total = response.contentLength ?? 0;
      int received = 0;
      final sink = File(zipPath).openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total * 0.8, 'Скачиваю... ${(received / 1024 / 1024).toStringAsFixed(1)} MB');
      }
      await sink.close();
      onProgress(0.82, 'Распаковываю...');

      // 2. Распаковываем
      final extractOk = await _extract(zipPath, updateDir);
      if (!extractOk) return false;
      await File(zipPath).delete().catchError((_) => File(zipPath));
      onProgress(0.95, 'Применяю обновление...');

      // 3. Запускаем скрипт обновления и выходим
      final exeDir = p.dirname(Platform.resolvedExecutable);
      await _launchUpdateScript(updateDir, exeDir);
      return true;
    } catch (e) {
      AppLogger.log('Ошибка обновления: $e');
      return false;
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
      await File(bat).writeAsString(
        '@echo off\r\n'
        'timeout /t 2 /nobreak >nul\r\n'
        'xcopy /s /e /y "$srcDir\\*" "$exeDir\\" >nul\r\n'
        'start "" "$exePath"\r\n'
        '(goto) 2>nul & del "%~f0"\r\n'
        .replaceAll(r'$srcDir', srcDir)
        .replaceAll(r'$exeDir', exeDir)
        .replaceAll(r'$exePath', exePath),
      );
      await Process.start('cmd', ['/c', bat],
          mode: ProcessStartMode.detached, runInShell: false);
    } else {
      final sh = p.join(tempDir, 'brandmen_apply_update.sh');
      final appBundle = p.normalize(p.join(exeDir, '..', '..', '..'));
      await File(sh).writeAsString(
        '#!/bin/bash\n'
        'sleep 2\n'
        'cp -R "$srcDir/"* "$exeDir/"\n'
        'open "$appBundle"\n'
        'rm -- "\$0"\n'
        .replaceAll(r'$srcDir', srcDir)
        .replaceAll(r'$exeDir', exeDir)
        .replaceAll(r'$appBundle', appBundle),
      );
      await Process.run('chmod', ['+x', sh]);
      await Process.start('bash', [sh], mode: ProcessStartMode.detached);
    }
    exit(0);
  }

  static bool _isNewer(String remote, String local) {
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
