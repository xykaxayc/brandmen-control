import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'logger.dart';

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
      final userProfile = Platform.environment['USERPROFILE'] ?? '';
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      candidates.addAll([
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
    _adbPath = Platform.isWindows ? 'adb.exe' : 'adb';
    return _adbPath!;
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

  // Прямая синхронизация: пушит видео и playlist.m3u через ADB на планшет.
  // Возвращает количество скачанных файлов.
  Future<int> syncDeviceDirect(String ip, String localDir) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final localFolder = Directory(localDir);
    if (!await localFolder.exists()) {
      AppLogger.log("Sync $ip: локальная папка не найдена");
      return 0;
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

    int pushed = 0;
    for (final f in localFiles) {
      final name = p.basename(f.path);
      final localSize = await f.length();
      final isPlaylist = name.toLowerCase() == 'playlist.m3u';

      // playlist.m3u пушим ВСЕГДА (содержимое могло изменится при том же размере)
      if (!isPlaylist && remoteSizes[name] == localSize) continue;

      AppLogger.log("Sync $ip: push $name");
      final res = await _run(
          adb, ['-s', id, 'push', f.path, '$_remoteDir/$name'],
          timeout: const Duration(seconds: 300));
      if (res.exitCode == 0) pushed++;
    }

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

  // Громкость 0..15 (поток MUSIC)
  Future<void> setVolume(String ip, int level) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final clamped = level.clamp(0, 15);
    await _run(adb,
        ['-s', id, 'shell', 'cmd', 'audio', 'set-volume', '3', '$clamped']);
  }

  Future<int> getVolume(String ip) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final r = await _run(
        adb, ['-s', id, 'shell', 'cmd', 'audio', 'get-volume', '3'],
        timeout: const Duration(seconds: 4));
    final match = RegExp(r'\d+').firstMatch(r.stdout.toString());
    if (match != null) return int.tryParse(match.group(0)!) ?? 8;
    return 8;
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

