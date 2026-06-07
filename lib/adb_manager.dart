import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'logger.dart';
import 'device_http.dart';
import 'transcoder.dart';
import 'media_config.dart';

class DeviceStatus {
  final String ip;
  final bool online;
  final String battery;
  final bool httpAvailable;
  final bool adbOnline;
  final String? lastError;
  // Данные из /health плеера (если доступен по HTTP).
  final String? playerVersion;
  final int? freeMb;
  final bool? playerPlaying;
  final String? currentClip;
  // true — плеер device owner, обновления ставятся молча; false — нужен ручной
  // тап «Установить»; null — статус неизвестен (старый плеер / нет HTTP).
  final bool? deviceOwner;

  DeviceStatus({
    required this.ip,
    required this.online,
    this.battery = "??",
    this.httpAvailable = false,
    this.adbOnline = false,
    this.lastError,
    this.playerVersion,
    this.freeMb,
    this.playerPlaying,
    this.currentClip,
    this.deviceOwner,
  });

  String get transport {
    if (httpAvailable && adbOnline) return 'HTTP + ADB';
    if (httpAvailable) return 'HTTP';
    if (adbOnline) return 'ADB';
    return 'offline';
  }
}

class SyncResult {
  final bool success;
  final List<String> pushed;
  final String? error;
  final String transport;
  final bool usedFallback;

  const SyncResult({
    required this.success,
    required this.pushed,
    this.error,
    this.transport = 'none',
    this.usedFallback = false,
  });
}

// Результат установки APK на планшет
enum ApkInstallResult {
  installed, // adb install -r прошёл успешно
  pushedToDownloads, // авто-установка не удалась, но файл в /sdcard/Download
  failed, // не удалось ни установить, ни скопировать
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

      final zipPath =
          p.join(Directory.systemTemp.path, 'platform-tools-win.zip');
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

  static Future<T> _retry<T>(
    String label,
    Future<T> Function() action,
    bool Function(T value) isSuccess, {
    int attempts = 3,
    Duration delay = const Duration(milliseconds: 700),
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

  static bool _ok(ProcessResult r) => r.exitCode == 0;

  // Список подключённых устройств в текущей ADB-сессии (id -> статус)
  Future<Map<String, String>> _listAdbDevices() async {
    final adb = await _getAdb();
    final r = await _run(adb, ['devices']);
    final out = r.stdout.toString();
    final map = <String, String>{};
    for (final line in out.split('\n')) {
      if (line.contains('\t')) {
        final parts = line.split('\t');
        if (parts.length >= 2 &&
            parts[0].trim().isNotEmpty &&
            !parts[0].startsWith('List')) {
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
    final httpAvailableFuture = DeviceHttp.isAvailable(ip);

    final current = await _listAdbDevices();
    var status = current[id];
    String? adbError;

    if (status != 'device') {
      // Пробуем переподключить
      await _run(adb, ['disconnect', id], timeout: const Duration(seconds: 2));
      final connectResult = await _retry(
        'ADB connect $id',
        () => _run(adb, ['connect', id], timeout: const Duration(seconds: 4)),
        (r) =>
            r.stdout.toString().toLowerCase().contains('connected') ||
            r.stdout.toString().toLowerCase().contains('already connected'),
      );
      final out = connectResult.stdout.toString().toLowerCase();
      if (!out.contains('connected')) {
        adbError = connectResult.stderr.toString().trim().isEmpty
            ? connectResult.stdout.toString().trim()
            : connectResult.stderr.toString().trim();
      }
      // Проверяем заново
      final after = await _listAdbDevices();
      status = after[id];
    }

    final adbOnline = status == 'device';
    final httpAvailable = await httpAvailableFuture;
    final battery = adbOnline ? await _getBattery(id) : "??";
    // Если доступен по HTTP — тянем /health (версия, место, что играет).
    Map<String, dynamic>? health;
    if (httpAvailable) {
      health = await DeviceHttp(ip).health();
    }
    return DeviceStatus(
      ip: ip,
      online: adbOnline || httpAvailable,
      battery: battery,
      httpAvailable: httpAvailable,
      adbOnline: adbOnline,
      lastError: adbOnline || httpAvailable ? null : adbError,
      playerVersion: health?['version'] as String?,
      freeMb: health?['freeMb'] as int?,
      playerPlaying: health?['playing'] as bool?,
      currentClip: health?['current'] as String?,
      deviceOwner: health?['deviceOwner'] as bool?,
    );
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
    final results = <DeviceStatus>[];
    const batchSize = 3;
    for (var i = 0; i < ips.length; i += batchSize) {
      final batch = ips.skip(i).take(batchSize);
      results.addAll(await Future.wait(batch.map(checkDevice)));
    }
    return results;
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
    final httpClient = DeviceHttp(ip);
    final woke = await httpClient.wake();
    if (launchPlayer) {
      final launched = await httpClient.launch();
      if (launched) return;
    } else if (woke) {
      return;
    }
    // ADB fallback
    final adb = await _getAdb();
    final id = '$ip:5555';
    await _retry(
      'wakeUp $ip',
      () => _run(adb, ['-s', id, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']),
      _ok,
    );
    await _run(adb, ['-s', id, 'shell', 'wm', 'dismiss-keyguard']);
    if (launchPlayer) {
      await _run(adb, ['-s', id, 'shell', 'am', 'force-stop', 'com.brandmen.ads'],
          timeout: const Duration(seconds: 4));
      await _run(adb,
          ['-s', id, 'shell', 'monkey', '-p', 'com.brandmen.ads',
           '-c', 'android.intent.category.LAUNCHER', '1'],
          timeout: const Duration(seconds: 6));
    }
  }

  /// Проверяет, что плеер РЕАЛЬНО играет, а не просто принял команду запуска.
  /// На HyperOS HTTP-launch может вернуть ok, но видео не выйдет на экран —
  /// поэтому опрашиваем /api/control/now несколько раз и ждём playing=true.
  Future<bool> verifyPlaying(String ip, {int attempts = 6}) async {
    final client = DeviceHttp(ip);
    for (int i = 0; i < attempts; i++) {
      await Future.delayed(const Duration(milliseconds: 800));
      final now = await client.controlNow();
      if (now != null && now['playing'] == true) {
        AppLogger.log('verifyPlaying $ip: играет (попытка ${i + 1})');
        return true;
      }
    }
    AppLogger.log('verifyPlaying $ip: НЕ играет после $attempts попыток');
    return false;
  }

  // Синхронизация: пробует HTTP (быстро, без ADB), иначе ADB.
  // Возвращает статус синхронизации и список имён отправленных файлов.
  Future<SyncResult> syncDeviceDirect(
    String ip,
    String localDir, {
    void Function(int done, int total, String filename)? onProgress,
    bool tryHttpFirst = true,
    bool Function()? isCancelled,
  }) async {
    final httpOk = tryHttpFirst && await DeviceHttp.isAvailable(ip);
    if (httpOk) {
      AppLogger.log('Sync $ip: используем HTTP (порт 5011)');
      final httpResult = await _syncViaHttp(ip, localDir,
          onProgress: onProgress, isCancelled: isCancelled);
      if (httpResult.success) return httpResult;

      // Пользователь нажал «Отмена» — не уходим в ADB-фолбэк.
      if (isCancelled?.call() ?? false) return httpResult;

      AppLogger.log(
          'Sync $ip: HTTP не завершился, пробую ADB fallback: ${httpResult.error}');
      final adbResult = await _syncViaAdb(ip, localDir, onProgress: onProgress);
      if (adbResult.success) {
        return SyncResult(
          success: true,
          pushed: adbResult.pushed,
          transport: adbResult.transport,
          usedFallback: true,
        );
      }
      return SyncResult(
        success: false,
        pushed: [...httpResult.pushed, ...adbResult.pushed],
        transport: 'HTTP -> ADB',
        usedFallback: true,
        error:
            'HTTP: ${httpResult.error ?? 'ошибка'}; ADB: ${adbResult.error ?? 'ошибка'}',
      );
    }
    AppLogger.log(tryHttpFirst
        ? 'Sync $ip: HTTP недоступен, используем ADB'
        : 'Sync $ip: используем ADB без проверки HTTP');
    return _syncViaAdb(ip, localDir, onProgress: onProgress);
  }

  Future<SyncResult> _syncViaHttp(
    String ip,
    String localDir, {
    void Function(int done, int total, String filename)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = DeviceHttp(ip);
    final localFolder = Directory(localDir);
    if (!await localFolder.exists()) {
      return const SyncResult(
        success: false,
        pushed: [],
        error: 'Локальная папка с видео не найдена',
        transport: 'HTTP',
      );
    }

    final remoteFiles = await client.listFiles();
    if (remoteFiles == null) {
      return const SyncResult(
        success: false,
        pushed: [],
        error: 'планшет не отдал список файлов',
        transport: 'HTTP',
      );
    }

    final localFiles = localFolder.listSync().whereType<File>().where((f) {
      final name = p.basename(f.path);
      final lower = name.toLowerCase();
      if (lower.startsWith('.')) return false;
      // Исходник заменён сконвертированным mp4 — не отправляем его.
      if (Transcoder.hasMp4Twin(localDir, name)) return false;
      return lower == 'playlist.m3u' || isVideoFile(lower);
    }).toList();

    // Проверка свободного места на планшете перед заливкой: считаем, сколько
    // байт реально нужно докачать, и сверяем с /health (запас 50 МБ).
    int needBytes = 0;
    for (final f in localFiles) {
      final name = p.basename(f.path);
      final isPlaylist = name.toLowerCase() == 'playlist.m3u';
      final sz = await f.length();
      if (isPlaylist || remoteFiles[name] != sz) needBytes += sz;
    }
    if (needBytes > 0) {
      final health = await client.health();
      if (health != null) {
        final freeBytes = (health['freeMb'] as int) * 1024 * 1024;
        if (freeBytes < needBytes + 50 * 1024 * 1024) {
          final needMb = (needBytes / 1024 / 1024).round();
          AppLogger.log('HTTP sync $ip: мало места — нужно $needMb МБ, '
              'свободно ${health['freeMb']} МБ');
          return SyncResult(
            success: false,
            pushed: const [],
            error: 'Недостаточно места на планшете: '
                'нужно ~$needMb МБ, свободно ${health['freeMb']} МБ',
            transport: 'HTTP',
          );
        }
      }
    }

    final List<String> pushed = [];
    final List<String> failed = [];
    // Один клиент на всю сессию: TCP-соединение переиспользуется (keep-alive)
    // вместо пересоздания на каждый файл.
    final httpClient = http.Client();
    try {
      for (int i = 0; i < localFiles.length; i++) {
        if (isCancelled?.call() ?? false) {
          return SyncResult(
              success: false, pushed: pushed, error: 'Отменено', transport: 'HTTP');
        }
        final f = localFiles[i];
        final name = p.basename(f.path);
        final isPlaylist = name.toLowerCase() == 'playlist.m3u';
        final localSize = await f.length();

        onProgress?.call(i, localFiles.length, name);

        if (!isPlaylist && remoteFiles[name] == localSize) continue;

        AppLogger.log(
            'HTTP sync $ip: upload $name (${(localSize / 1024 / 1024).toStringAsFixed(1)} MB)');
        final ok = await client.uploadFile(f, client: httpClient);
        if (ok && !isPlaylist) pushed.add(name);
        if (!ok) failed.add(name);
      }
    } finally {
      httpClient.close();
    }
    onProgress?.call(localFiles.length, localFiles.length, '');

    // Чистим лишнее на устройстве ТОЛЬКО если все заливки прошли успешно —
    // иначе при неполной синхронизации можно удалить рабочий файл, замена
    // которому не докачалась.
    if (failed.isEmpty) {
      final localNames = localFiles.map((f) => p.basename(f.path)).toSet();
      for (final remoteName in remoteFiles.keys) {
        if (!localNames.contains(remoteName) && isVideoFile(remoteName)) {
          AppLogger.log('HTTP sync $ip: удаляю $remoteName');
          final ok = await client.deleteFile(remoteName);
          if (!ok) failed.add('удаление $remoteName');
        }
      }
    } else {
      AppLogger.log('HTTP sync $ip: были ошибки заливки — пропускаю очистку '
          'лишних файлов, чтобы не удалить рабочий контент');
    }
    if (failed.isNotEmpty) {
      return SyncResult(
        success: false,
        pushed: pushed,
        error: 'Не удалось передать: ${failed.join(', ')}',
        transport: 'HTTP',
      );
    }
    return SyncResult(success: true, pushed: pushed, transport: 'HTTP');
  }

  Future<SyncResult> _syncViaAdb(
    String ip,
    String localDir, {
    void Function(int done, int total, String filename)? onProgress,
  }) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final localFolder = Directory(localDir);
    if (!await localFolder.exists()) {
      AppLogger.log("Sync $ip: локальная папка не найдена");
      return const SyncResult(
        success: false,
        pushed: [],
        error: 'Локальная папка с видео не найдена',
        transport: 'ADB',
      );
    }

    final mkdir = await _retry(
      'ADB mkdir $ip',
      () => _run(adb, ['-s', id, 'shell', 'mkdir', '-p', _remoteDir],
          timeout: const Duration(seconds: 4)),
      _ok,
    );
    if (mkdir.exitCode != 0) {
      return SyncResult(
        success: false,
        pushed: const [],
        error: 'ADB недоступен: ${mkdir.stderr}${mkdir.stdout}',
        transport: 'ADB',
      );
    }

    final remoteSizes = await _remoteSizes(adb, id);

    final localFiles = localFolder.listSync().whereType<File>().where((f) {
      final name = p.basename(f.path);
      final lower = name.toLowerCase();
      if (lower.startsWith('.')) return false;
      // Исходник заменён сконвертированным mp4 — не отправляем его.
      if (Transcoder.hasMp4Twin(localDir, name)) return false;
      return lower == 'playlist.m3u' || isVideoFile(lower);
    }).toList();

    final List<String> pushed = [];
    final List<String> failed = [];
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

      AppLogger.log(
          "Sync $ip: push $name (${(localSize / 1024 / 1024).toStringAsFixed(1)} MB)");
      final res = await _retry(
        'ADB push $ip/$name',
        () => _run(adb, ['-s', id, 'push', f.path, '$_remoteDir/$name'],
            timeout: const Duration(seconds: 300)),
        _ok,
      );
      if (res.exitCode == 0 && !isPlaylist) pushed.add(name);
      if (res.exitCode != 0) {
        failed.add(name);
        AppLogger.log(
            "Sync $ip: push $name не удался: ${res.stdout}${res.stderr}");
      }
    }
    onProgress?.call(allOrdered.length, allOrdered.length, '');

    final localNames = localFiles.map((f) => p.basename(f.path)).toSet();
    for (final remoteName in remoteSizes.keys) {
      if (!localNames.contains(remoteName) && isVideoFile(remoteName)) {
        AppLogger.log("Sync $ip: удаляю $remoteName");
        final quoted = _shellQuote('$_remoteDir/$remoteName');
        final res = await _retry(
          'ADB delete $ip/$remoteName',
          () => _run(adb, ['-s', id, 'shell', 'rm', '-f', '--', quoted],
              timeout: const Duration(seconds: 5)),
          _ok,
          attempts: 2,
        );
        if (res.exitCode != 0) {
          failed.add('удаление $remoteName');
          AppLogger.log(
              "Sync $ip: удаление $remoteName не удалось: ${res.stdout}${res.stderr}");
        }
      }
    }

    if (failed.isNotEmpty) {
      return SyncResult(
        success: false,
        pushed: pushed,
        error: 'Не удалось передать: ${failed.join(', ')}',
        transport: 'ADB',
      );
    }
    return SyncResult(success: true, pushed: pushed, transport: 'ADB');
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", r"'\''")}'";
  }

  /// {имя файла: размер} для файлов в _remoteDir на устройстве.
  ///
  /// Главный способ — `stat`: отдаёт «размер|полный путь», что надёжно при
  /// пробелах в именах. Раньше парсился `ls -l` по фиксированным колонкам
  /// (размер=parts[4], имя=parts[7+]), но формат `ls` отличается между
  /// прошивками (порядок колонок и формат даты), парсинг ломался → планшет
  /// считался пустым → синк лил ВСЕ файлы заново на каждом запуске.
  /// Команду шлём одной строкой: `adb shell` склеивает аргументы, а кавычки
  /// разбирает шелл устройства — иначе пробел в `-c '%s|%n'` всё ломает.
  static Future<Map<String, int>> _remoteSizes(String adb, String id) async {
    final result = <String, int>{};

    final statRes = await _run(
      adb,
      ['-s', id, 'shell', "stat -c '%s|%n' $_remoteDir/* 2>/dev/null"],
      timeout: const Duration(seconds: 8),
    );
    for (final line in statRes.stdout.toString().split('\n')) {
      final t = line.trim();
      final bar = t.indexOf('|');
      if (bar <= 0) continue;
      final size = int.tryParse(t.substring(0, bar));
      if (size == null) continue;
      final name = p.basename(t.substring(bar + 1).trim());
      if (name.isEmpty || name == '*') continue;
      result[name] = size;
    }
    if (result.isNotEmpty) return result;

    // Фолбэк: старый разбор `ls -l`, если на устройстве нет `stat`.
    final lsRes = await _run(adb, ['-s', id, 'shell', 'ls', '-l', _remoteDir],
        timeout: const Duration(seconds: 6));
    for (final line in lsRes.stdout.toString().split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 8) {
        final size = int.tryParse(parts[4]);
        if (size != null) {
          result[parts.sublist(7).join(' ')] = size;
        }
      }
    }
    return result;
  }

  Future<void> sleep(String ip) async {
    if (await DeviceHttp(ip).httpSleep()) return;
    // ADB fallback
    final adb = await _getAdb();
    final id = '$ip:5555';
    await _retry(
      'sleep $ip',
      () => _run(adb, ['-s', id, 'shell', 'input', 'keyevent', 'KEYCODE_SLEEP']),
      _ok,
      attempts: 2,
    );
  }

  Future<void> setVolume(String ip, int level) async {
    if (await DeviceHttp(ip).setVolumeHttp(level)) return;
    // ADB fallback
    final adb = await _getAdb();
    final id = '$ip:5555';
    await _run(adb, [
      '-s', id, 'shell', 'cmd', 'media_session', 'volume',
      '--stream', '3', '--set', '${level.clamp(0, 15)}', '--show'
    ]);
  }

  Future<int> getVolume(String ip) async {
    final status = await DeviceHttp(ip).controlStatus();
    if (status != null) return status['volume']!;
    // ADB fallback
    final adb = await _getAdb();
    final id = '$ip:5555';
    final r = await _run(adb,
        ['-s', id, 'shell', 'cmd', 'media_session', 'volume', '--stream', '3', '--get'],
        timeout: const Duration(seconds: 4));
    final out = r.stdout.toString() + r.stderr.toString();
    final match = RegExp(r'volume is (\d+)').firstMatch(out);
    if (match != null) return int.tryParse(match.group(1)!) ?? 8;
    final any = RegExp(r'\d+').firstMatch(out);
    return any != null ? (int.tryParse(any.group(0)!) ?? 8) : 8;
  }

  // Максимум громкости устройства (HTTP), по умолчанию 15.
  Future<int> getVolumeMax(String ip) async {
    final status = await DeviceHttp(ip).controlStatus();
    return status?['volumeMax'] ?? 15;
  }

  Future<void> setBrightness(String ip, int level) async {
    if (await DeviceHttp(ip).setBrightnessHttp(level)) return;
    // ADB fallback
    final adb = await _getAdb();
    final id = '$ip:5555';
    await _run(adb, ['-s', id, 'shell', 'settings', 'put', 'system', 'screen_brightness_mode', '0']);
    await _run(adb, ['-s', id, 'shell', 'settings', 'put', 'system',
        'screen_brightness', '${level.clamp(1, 255)}']);
  }

  Future<int> getBrightness(String ip) async {
    final status = await DeviceHttp(ip).controlStatus();
    if (status != null) return status['brightness']!;
    // ADB fallback
    final adb = await _getAdb();
    final id = '$ip:5555';
    final r = await _run(adb,
        ['-s', id, 'shell', 'settings', 'get', 'system', 'screen_brightness'],
        timeout: const Duration(seconds: 4));
    return int.tryParse(r.stdout.toString().trim()) ?? 128;
  }

  // Регистрация: получает IP USB-планшета, включает TCP, возвращает IP
  Future<String?> registerViaUsb(String usbDeviceId) async {
    final adb = await _getAdb();
    try {
      final ipResult =
          await _run(adb, ['-s', usbDeviceId, 'shell', 'ip', 'route']);
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
      await _run(adb, ['-s', usbDeviceId, 'tcpip', '5555'],
          timeout: const Duration(seconds: 6));
      await Future.delayed(const Duration(seconds: 2));
      await _run(adb, ['connect', '$ip:5555'],
          timeout: const Duration(seconds: 5));
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

  // Возвращает версию APK с планшета через HTTP /version, или null если недоступен.
  static Future<String?> getApkVersion(String ip) async {
    try {
      final response = await http
          .get(Uri.parse('http://$ip:$kDeviceHttpPort/version'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return (data['version'] as String? ?? '0.0.0');
      }
    } catch (_) {}
    return null;
  }

  // Устанавливает APK: всегда кладёт копию в /sdcard/Download (ручной фолбэк
  // на случай если установка по ADB запрещена политикой устройства), плюс
  // пробует авто-установку через adb install -r.
  Future<ApkInstallResult> installApk(String ip, String apkPath) async {
    final adb = await _getAdb();
    final id = '$ip:5555';

    // 1. Копия в «Загрузки» — гарантированный ручной способ установки
    final push = await _run(
        adb, ['-s', id, 'push', apkPath, '/sdcard/Download/BrandmenAds.apk'],
        timeout: const Duration(minutes: 5));
    final pushOk = push.exitCode == 0;
    if (!pushOk) {
      AppLogger.log('installApk $ip: push в Download не удался: '
          '${push.stdout}${push.stderr}');
    }

    // 2. Пробуем установить автоматически
    final r = await _run(adb, ['-s', id, 'install', '-r', apkPath],
        timeout: const Duration(minutes: 5));
    final out = r.stdout.toString() + r.stderr.toString();
    final installed = r.exitCode == 0 && out.toLowerCase().contains('success');
    if (installed) return ApkInstallResult.installed;

    AppLogger.log('installApk $ip: авто-установка не удалась '
        '(code=${r.exitCode} $out)');
    return pushOk
        ? ApkInstallResult.pushedToDownloads
        : ApkInstallResult.failed;
  }

  Future<String?> takeScreenshot(String ip, String savePath) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    try {
      await _run(adb, ['-s', id, 'shell', 'rm', '-f', '/sdcard/screen.png'],
          timeout: const Duration(seconds: 4));
      final cap = await _run(
          adb, ['-s', id, 'shell', 'screencap', '-p', '/sdcard/screen.png'],
          timeout: const Duration(seconds: 6));
      if (cap.exitCode != 0) return null;
      final pull = await _run(
          adb, ['-s', id, 'pull', '/sdcard/screen.png', savePath],
          timeout: const Duration(seconds: 6));
      if (pull.exitCode != 0) return null;
      return savePath;
    } catch (e) {
      AppLogger.log("Ошибка скриншота ($ip): $e");
      return null;
    }
  }
}
