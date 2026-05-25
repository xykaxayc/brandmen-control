import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'logger.dart';
import 'device_http.dart';

class DeviceStatus {
  final String ip;
  final bool online;
  final String battery;
  DeviceStatus({required this.ip, required this.online, this.battery = "??"});
}

class AdbManager {
  static String? _adbPath;

  static Future<String> _getAdb() async {
    if (_adbPath != null) return _adbPath!;
    final candidates = <String>[];
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final appData = Platform.environment['APPDATA'] ?? '';
      final userProfile = Platform.environment['USERPROFILE'] ?? '';
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      candidates.addAll([
        // Рядом с exe (портативная сборка — бандл из CI)
        p.join(exeDir, 'platform-tools', 'adb.exe'),
        p.join(exeDir, 'adb.exe'),
        // Авто-скачанный при первом запуске
        if (appData.isNotEmpty)
          p.join(appData, 'Brandmen', 'platform-tools', 'adb.exe'),
        // Стандартные места установки
        'C:\\platform-tools\\adb.exe',
        'C:\\Android\\platform-tools\\adb.exe',
        'C:\\Program Files (x86)\\Android\\android-sdk\\platform-tools\\adb.exe',
        'C:\\Program Files\\Android\\android-sdk\\platform-tools\\adb.exe',
        if (localAppData.isNotEmpty)
          '$localAppData\\Android\\Sdk\\platform-tools\\adb.exe',
        if (userProfile.isNotEmpty)
          '$userProfile\\AppData\\Local\\Android\\Sdk\\platform-tools\\adb.exe',
      ]);
    } else {
      candidates.addAll([
        '/opt/homebrew/bin/adb',
        '/usr/local/bin/adb',
        '/usr/bin/adb',
      ]);
    }
    for (final path in candidates) {
      if (await File(path).exists()) {
        _adbPath = path;
        return path;
      }
    }
    // На Windows — попробуем скачать автоматически
    if (Platform.isWindows) {
      final downloaded = await _downloadAdbWindows();
      if (downloaded != null) {
        _adbPath = downloaded;
        return downloaded;
      }
    }
    _adbPath = Platform.isWindows ? 'adb.exe' : 'adb';
    return _adbPath!;
  }

  static Future<String?> _downloadAdbWindows() async {
    const url =
        'https://dl.google.com/android/repository/platform-tools-latest-windows.zip';
    try {
      final appData = Platform.environment['APPDATA'] ?? '';
      if (appData.isEmpty) return null;
      final targetDir = p.join(appData, 'Brandmen', 'platform-tools');
      final adbPath = p.join(targetDir, 'adb.exe');
      if (await File(adbPath).exists()) return adbPath;

      AppLogger.log('ADB не найден, скачиваю platform-tools...');
      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(minutes: 5));
      if (response.statusCode != 200) return null;

      final zipPath = p.join(Directory.systemTemp.path, 'platform-tools-win.zip');
      await File(zipPath).writeAsBytes(response.bodyBytes);

      final extractTo = p.join(appData, 'Brandmen');
      await Directory(extractTo).create(recursive: true);
      final res = await Process.run('powershell', [
        '-Command',
        'Expand-Archive -Path "$zipPath" -DestinationPath "$extractTo" -Force',
      ]);
      await File(zipPath).delete().catchError((_) => File(zipPath));

      if (res.exitCode == 0 && await File(adbPath).exists()) {
        AppLogger.log('ADB скачан: $adbPath');
        return adbPath;
      }
    } catch (e) {
      AppLogger.log('Ошибка скачивания ADB: $e');
    }
    return null;
  }

  static Future<ProcessResult> _run(String adb, List<String> args,
      {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      return await Process.run(adb, args).timeout(timeout);
    } on TimeoutException {
      return ProcessResult(0, -1, '', 'timeout');
    } catch (e) {
      return ProcessResult(0, -1, '', e.toString());
    }
  }

  // Список подключённых устройств в текущей ADB-сессии (id -> статус)
  Future<Map<String, String>> _listAdbDevices() async {
    final adb = await _getAdb();
    final r = await _run(adb, ['devices']);
    final out = r.stdout.toString();
    final map = <String, String>{};
    for (final line in out.split('\n')) {
      if (line.contains('\t')) {
        final parts = line.split('\t');
        if (parts.length >= 2 && parts[0].trim().isNotEmpty && !parts[0].startsWith('List')) {
          map[parts[0].trim()] = parts[1].trim();
        }
      }
    }
    return map;
  }

  // Проверяет статус одного устройства по IP, при необходимости переподключает
  Future<DeviceStatus> checkDevice(String ip) async {
    final adb = await _getAdb();
    final id = '$ip:5555';

    final current = await _listAdbDevices();
    var status = current[id];

    if (status != 'device') {
      // Пробуем переподключить
      await _run(adb, ['disconnect', id], timeout: const Duration(seconds: 2));
      final connectResult = await _run(adb, ['connect', id], timeout: const Duration(seconds: 4));
      final out = connectResult.stdout.toString().toLowerCase();
      if (!out.contains('connected')) {
        return DeviceStatus(ip: ip, online: false);
      }
      // Проверяем заново
      final after = await _listAdbDevices();
      status = after[id];
      if (status != 'device') {
        return DeviceStatus(ip: ip, online: false);
      }
    }

    final battery = await _getBattery(id);
    return DeviceStatus(ip: ip, online: true, battery: battery);
  }

  Future<String> _getBattery(String id) async {
    final adb = await _getAdb();
    try {
      final r = await _run(adb, ['-s', id, 'shell', 'dumpsys', 'battery'],
          timeout: const Duration(seconds: 4));
      final out = r.stdout.toString();
      for (final line in out.split('\n')) {
        if (line.contains('level:')) {
          return line.split(':')[1].trim();
        }
      }
    } catch (_) {}
    return "??";
  }

  // Проверяет все IP параллельно
  Future<List<DeviceStatus>> checkAll(List<String> ips) async {
    if (ips.isEmpty) return [];
    return Future.wait(ips.map(checkDevice));
  }

  // Очищает все offline-соединения из ADB-кэша
  Future<void> cleanupOffline() async {
    final adb = await _getAdb();
    final current = await _listAdbDevices();
    final toRemove = current.entries
        .where((e) => e.value == 'offline' && e.key.contains(':'))
        .map((e) => e.key)
        .toList();
    for (final id in toRemove) {
      await _run(adb, ['disconnect', id], timeout: const Duration(seconds: 2));
    }
    if (toRemove.isNotEmpty) {
      AppLogger.log("Очищено offline соединений: ${toRemove.length}");
    }
  }

  Future<void> bulkSleep(List<String> ips) async {
    await Future.wait(ips.map(sleep));
  }

  static const _remoteDir = '/sdcard/Movies/ads';

  // Будит экран, опционально запускает плеер заново (force-stop + monkey)
  Future<void> wakeUp(String ip, {bool launchPlayer = false}) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    await _run(adb, ['-s', id, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
    await _run(adb, ['-s', id, 'shell', 'wm', 'dismiss-keyguard']);
    if (launchPlayer) {
      await _run(adb, ['-s', id, 'shell', 'am', 'force-stop', 'com.brandmen.ads'],
          timeout: const Duration(seconds: 4));
      await _run(adb, ['-s', id, 'shell', 'monkey', '-p', 'com.brandmen.ads',
          '-c', 'android.intent.category.LAUNCHER', '1'], timeout: const Duration(seconds: 6));
    }
  }

  // Синхронизация: пробует HTTP (быстро, без ADB), иначе ADB.
  // Возвращает список имён отправленных файлов. onProgress — колбэк прогресса.
  Future<List<String>> syncDeviceDirect(
    String ip,
    String localDir, {
    void Function(int done, int total, String filename)? onProgress,
  }) async {
    final httpOk = await DeviceHttp.isAvailable(ip);
    if (httpOk) {
      AppLogger.log('Sync $ip: используем HTTP (порт 5011)');
      return _syncViaHttp(ip, localDir, onProgress: onProgress);
    }
    AppLogger.log('Sync $ip: HTTP недоступен, используем ADB');
    return _syncViaAdb(ip, localDir, onProgress: onProgress);
  }

  Future<List<String>> _syncViaHttp(
    String ip,
    String localDir, {
    void Function(int done, int total, String filename)? onProgress,
  }) async {
    final client = DeviceHttp(ip);
    final localFolder = Directory(localDir);
    if (!await localFolder.exists()) return [];

    final remoteFiles = await client.listFiles();

    final localFiles = localFolder.listSync().whereType<File>().where((f) {
      final name = p.basename(f.path).toLowerCase();
      if (name.startsWith('.')) return false;
      return name == 'playlist.m3u' ||
          ['.mp4', '.mkv', '.mov', '.avi', '.webm']
              .contains(p.extension(name));
    }).toList();

    final List<String> pushed = [];
    for (int i = 0; i < localFiles.length; i++) {
      final f = localFiles[i];
      final name = p.basename(f.path);
      final isPlaylist = name.toLowerCase() == 'playlist.m3u';
      final localSize = await f.length();

      onProgress?.call(i, localFiles.length, name);

      if (!isPlaylist && remoteFiles[name] == localSize) continue;

      AppLogger.log(
          'HTTP sync $ip: upload $name (${(localSize / 1024 / 1024).toStringAsFixed(1)} MB)');
      final ok = await client.uploadFile(f);
      if (ok && !isPlaylist) pushed.add(name);
    }
    onProgress?.call(localFiles.length, localFiles.length, '');

    // Удаляем лишние файлы на устройстве
    final localNames =
        localFiles.map((f) => p.basename(f.path)).toSet();
    for (final remoteName in remoteFiles.keys) {
      if (!localNames.contains(remoteName) &&
          ['.mp4', '.mkv', '.mov', '.avi', '.webm']
              .contains(p.extension(remoteName).toLowerCase())) {
        AppLogger.log('HTTP sync $ip: удаляю $remoteName');
        await client.deleteFile(remoteName);
      }
    }
    return pushed;
  }

  Future<List<String>> _syncViaAdb(
    String ip,
    String localDir, {
    void Function(int done, int total, String filename)? onProgress,
  }) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final localFolder = Directory(localDir);
    if (!await localFolder.exists()) {
      AppLogger.log("Sync $ip: локальная папка не найдена");
      return [];
    }

    await _run(adb, ['-s', id, 'shell', 'mkdir', '-p', _remoteDir],
        timeout: const Duration(seconds: 4));

    final lsRes = await _run(adb, ['-s', id, 'shell', 'ls', '-l', _remoteDir],
        timeout: const Duration(seconds: 6));
    final remoteSizes = <String, int>{};
    for (final line in lsRes.stdout.toString().split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 5) {
        final size = int.tryParse(parts[4]);
        if (size != null && parts.length > 7) {
          final name = parts.sublist(7).join(' ');
          remoteSizes[name] = size;
        }
      }
    }

    final localFiles = localFolder.listSync().whereType<File>().where((f) {
      final name = p.basename(f.path).toLowerCase();
      if (name.startsWith('.')) return false;
      return name == 'playlist.m3u' ||
          ['.mp4', '.mkv', '.mov', '.avi', '.webm'].contains(p.extension(name));
    }).toList();

    final List<String> pushed = [];
    final videoFiles = localFiles.where((f) {
      final ext = p.extension(p.basename(f.path)).toLowerCase();
      return ext != '.m3u';
    }).toList();
    final playlistFiles = localFiles.where((f) {
      return p.basename(f.path).toLowerCase() == 'playlist.m3u';
    }).toList();
    final allOrdered = [...videoFiles, ...playlistFiles];

    for (int i = 0; i < allOrdered.length; i++) {
      final f = allOrdered[i];
      final name = p.basename(f.path);
      final localSize = await f.length();
      final isPlaylist = name.toLowerCase() == 'playlist.m3u';

      onProgress?.call(i, allOrdered.length, name);

      // playlist.m3u пушим ВСЕГДА (содержимое могло изменится при том же размере)
      if (!isPlaylist && remoteSizes[name] == localSize) continue;

      AppLogger.log("Sync $ip: push $name (${(localSize / 1024 / 1024).toStringAsFixed(1)} MB)");
      final res = await _run(
          adb, ['-s', id, 'push', f.path, '$_remoteDir/$name'],
          timeout: const Duration(seconds: 300));
      if (res.exitCode == 0 && !isPlaylist) pushed.add(name);
    }
    onProgress?.call(allOrdered.length, allOrdered.length, '');

    final localNames = localFiles.map((f) => p.basename(f.path)).toSet();
    for (final remoteName in remoteSizes.keys) {
      if (!localNames.contains(remoteName) &&
          ['.mp4', '.mkv', '.mov', '.avi', '.webm']
              .contains(p.extension(remoteName).toLowerCase())) {
        AppLogger.log("Sync $ip: удаляю $remoteName");
        await _run(adb, ['-s', id, 'shell', 'rm', '$_remoteDir/$remoteName'],
            timeout: const Duration(seconds: 5));
      }
    }

    return pushed;
  }

  Future<void> sleep(String ip) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    await _run(adb, ['-s', id, 'shell', 'input', 'keyevent', 'KEYCODE_SLEEP']);
  }

  // Громкость 0..15 (поток MUSIC). На MIUI требуется --show, иначе тихо игнорится.
  Future<void> setVolume(String ip, int level) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final clamped = level.clamp(0, 15);
    await _run(adb, [
      '-s', id, 'shell', 'cmd', 'media_session', 'volume',
      '--stream', '3', '--set', '$clamped', '--show'
    ]);
  }

  Future<int> getVolume(String ip) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final r = await _run(adb, [
      '-s', id, 'shell', 'cmd', 'media_session', 'volume',
      '--stream', '3', '--get'
    ], timeout: const Duration(seconds: 4));
    final out = r.stdout.toString() + r.stderr.toString();
    // Вывод примерно: "volume is 8 in range [0..15]"
    final match = RegExp(r'volume is (\d+)').firstMatch(out);
    if (match != null) return int.tryParse(match.group(1)!) ?? 8;
    final any = RegExp(r'\d+').firstMatch(out);
    return any != null ? (int.tryParse(any.group(0)!) ?? 8) : 8;
  }

  // Яркость 0..255
  Future<void> setBrightness(String ip, int level) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final clamped = level.clamp(1, 255);
    await _run(adb, [
      '-s', id, 'shell', 'settings', 'put', 'system',
      'screen_brightness_mode', '0'
    ]);
    await _run(adb, [
      '-s', id, 'shell', 'settings', 'put', 'system',
      'screen_brightness', '$clamped'
    ]);
  }

  Future<int> getBrightness(String ip) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final r = await _run(adb,
        ['-s', id, 'shell', 'settings', 'get', 'system', 'screen_brightness'],
        timeout: const Duration(seconds: 4));
    final v = int.tryParse(r.stdout.toString().trim());
    return v ?? 128;
  }

  // Регистрация: получает IP USB-планшета, включает TCP, возвращает IP
  Future<String?> registerViaUsb(String usbDeviceId) async {
    final adb = await _getAdb();
    try {
      final ipResult = await _run(adb, ['-s', usbDeviceId, 'shell', 'ip', 'route']);
      final ipOutput = ipResult.stdout.toString();
      String? ip;
      for (final line in ipOutput.split('\n')) {
        final match = RegExp(r'src (\d+\.\d+\.\d+\.\d+)').firstMatch(line);
        if (match != null) {
          ip = match.group(1);
          break;
        }
      }

      if (ip == null || ip.isEmpty) {
        AppLogger.log("USB ($usbDeviceId): не удалось получить IP");
        return null;
      }

      AppLogger.log("USB ($usbDeviceId): IP=$ip, включаем TCP/IP...");
      await _run(adb, ['-s', usbDeviceId, 'tcpip', '5555'], timeout: const Duration(seconds: 6));
      await Future.delayed(const Duration(seconds: 2));
      await _run(adb, ['connect', '$ip:5555'], timeout: const Duration(seconds: 5));
      AppLogger.log("USB: подключено $ip:5555");
      return ip;
    } catch (e) {
      AppLogger.log("Ошибка USB регистрации ($usbDeviceId): $e");
      return null;
    }
  }

  Future<List<String>> getUsbDevices() async {
    final all = await _listAdbDevices();
    return all.entries
        .where((e) => e.value == 'device' && !e.key.contains(':'))
        .map((e) => e.key)
        .toList();
  }

  // Возвращает версию APK с планшета через HTTP /version, или '0.0.0' если недоступен
  static Future<String> getApkVersion(String ip) async {
    try {
      final response = await http
          .get(Uri.parse('http://$ip:$kDeviceHttpPort/version'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return (data['version'] as String? ?? '0.0.0');
      }
    } catch (_) {}
    return '0.0.0';
  }

  // Устанавливает APK на планшет через ADB install -r
  Future<bool> installApk(String ip, String apkPath) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final r = await _run(adb, ['-s', id, 'install', '-r', apkPath],
        timeout: const Duration(minutes: 5));
    final out = r.stdout.toString() + r.stderr.toString();
    final success = r.exitCode == 0 && out.toLowerCase().contains('success');
    if (!success) AppLogger.log('installApk $ip: code=${r.exitCode} $out');
    return success;
  }

  Future<String?> takeScreenshot(String ip, String savePath) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    try {
      await _run(adb, ['-s', id, 'shell', 'rm', '-f', '/sdcard/screen.png'],
          timeout: const Duration(seconds: 4));
      final cap = await _run(adb, ['-s', id, 'shell', 'screencap', '-p', '/sdcard/screen.png'],
          timeout: const Duration(seconds: 6));
      if (cap.exitCode != 0) return null;
      final pull = await _run(adb, ['-s', id, 'pull', '/sdcard/screen.png', savePath],
          timeout: const Duration(seconds: 6));
      if (pull.exitCode != 0) return null;
      return savePath;
    } catch (e) {
      AppLogger.log("Ошибка скриншота ($ip): $e");
      return null;
    }
  }
}

