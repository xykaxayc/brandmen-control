import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'logger.dart';
import 'device_http.dart';
import 'transcoder.dart';
import 'media_config.dart';
import 'brand_pack.dart';
import 'deployment.dart';
import 'operation_event.dart';

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
  final bool? playbackEnabled;
  final String? currentClip;
  // true — плеер device owner, обновления ставятся молча; false — нужен ручной
  // тап «Установить»; null — статус неизвестен (старый плеер / нет HTTP).
  final bool? deviceOwner;
  // Диагностика доступов из /health (null — старый плеер не сообщает):
  // SHA-256 подписи APK, разрешение на установку, исключение из оптимизации
  // батареи, «поверх других приложений».
  final String? signature;
  final bool? canInstall;
  final bool? batteryExempt;
  final bool? overlay;
  final String? deviceId;
  final int? protocolVersion;
  final String? activeDeploymentId;
  final String? playlistHash;

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
    this.playbackEnabled,
    this.currentClip,
    this.deviceOwner,
    this.signature,
    this.canInstall,
    this.batteryExempt,
    this.overlay,
    this.deviceId,
    this.protocolVersion,
    this.activeDeploymentId,
    this.playlistHash,
  });

  /// Эталонная подпись CI-сборок APK (SHA-256 release.keystore из репо).
  /// Если планшет сообщает другую — обновления поверх не установятся.
  static const String expectedSignature =
      'ADB11DDA61FA878E0B60363BC1CDA0EE657E04362A0FC21167E46E13454B13D4';

  /// null — подпись неизвестна (старый плеер), true — совпадает с эталоном.
  bool? get signatureOk {
    final s = signature;
    if (s == null || s.isEmpty) return null;
    return s.toUpperCase() == expectedSignature;
  }

  String get transport {
    if (httpAvailable && adbOnline) return 'HTTP + ADB';
    if (httpAvailable) return 'HTTP';
    if (adbOnline) return 'ADB';
    return 'offline';
  }

  /// Готовность именно к автономному управлению по Wi‑Fi: плеер отвечает
  /// напрямую, а Device Owner сможет восстановить Wi‑Fi, перезагрузиться и
  /// применить обновление без человека у экрана.
  bool get fullWifiControlReady =>
      httpAvailable &&
      deviceOwner == true &&
      canInstall != false &&
      batteryExempt != false;

  String get wifiControlHint {
    if (!httpAvailable) return 'нет связи с плеером';
    if (deviceOwner != true) return 'нужно подготовить Device Owner';
    if (canInstall == false) return 'разрешите установку обновлений';
    if (batteryExempt == false) return 'исключите из экономии батареи';
    return 'готов к самостоятельному восстановлению';
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
  installed, // adb install -r прошёл успешно (тихо)
  dialogShown, // APK доставлен по HTTP, на планшете открылось окно установки
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
    Process? process;
    try {
      process = await Process.start(adb, args);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();

      final stdoutSub = process.stdout.transform(utf8.decoder).listen((data) {
        stdoutBuffer.write(data);
      });
      final stderrSub = process.stderr.transform(utf8.decoder).listen((data) {
        stderrBuffer.write(data);
      });

      final exitCode = await process.exitCode.timeout(timeout);

      await stdoutSub.cancel();
      await stderrSub.cancel();

      return ProcessResult(process.pid, exitCode, stdoutBuffer.toString(),
          stderrBuffer.toString());
    } on TimeoutException {
      if (process != null) {
        process.kill();
      }
      return ProcessResult(0, -1, '', 'timeout');
    } catch (e) {
      if (process != null) {
        process.kill();
      }
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

  // Проверяет статус одного устройства по IP, при необходимости переподключает.
  // [knownDevices] — заранее снятый снимок `adb devices` (checkAll снимает его
  // один раз на всех, а не по разу на устройство).
  Future<DeviceStatus> checkDevice(String ip,
      {Map<String, String>? knownDevices}) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    final httpAvailableFuture = DeviceHttp.isAvailable(ip);

    final current = knownDevices ?? await _listAdbDevices();
    var status = current[id];
    String? adbError;

    if (status != 'device') {
      // Пробуем переподключить (HTTP-проверка тем временем идёт параллельно).
      // Первая попытка — всегда; вторая — только если планшет молчит и по
      // HTTP (иначе ADB вторичен и не стоит лишних секунд). Третьей нет:
      // мёртвый IP от неё не оживал, а refresh с офлайн-планшетом
      // растягивался до ~16с.
      await _run(adb, ['disconnect', id], timeout: const Duration(seconds: 2));
      bool connected(ProcessResult r) =>
          r.stdout.toString().toLowerCase().contains('connected');
      var connectResult =
          await _run(adb, ['connect', id], timeout: const Duration(seconds: 4));
      if (!connected(connectResult) && !await httpAvailableFuture) {
        AppLogger.log('ADB connect $id: попытка 1/2 не удалась, повтор...');
        await Future.delayed(const Duration(milliseconds: 700));
        connectResult = await _run(adb, ['connect', id],
            timeout: const Duration(seconds: 4));
      }
      if (!connected(connectResult)) {
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
    // Если доступен по HTTP — тянем /health (версия, место, что играет).
    Map<String, dynamic>? health;
    if (httpAvailable) {
      health = await DeviceHttp(ip).health();
    }
    // Батарея: из /health, если плеер её отдаёт (без ADB-команды на каждый
    // refresh); иначе по ADB как раньше. Плеер шлёт -1, если уровень неизвестен.
    final healthBattery = health?['battery'] as int?;
    final battery = (healthBattery != null && healthBattery > 0)
        ? '$healthBattery'
        : (adbOnline ? await _getBattery(id) : "??");
    // Логируем РЕАЛЬНОЕ состояние планшета — иначе в логе видны только ошибки
    // и не понять, почему «не играет» (пустой плейлист / нет файла / завис).
    if (health != null) {
      AppLogger.log('[СТАТУС] $ip: online http=$httpAvailable adb=$adbOnline '
          'v${health['version']} долженИграть=${health['playbackEnabled']} '
          'играет=${health['playing']} '
          'ролик="${health['current']}" плейлист=${health['index']}/${health['total']} '
          'место=${health['freeMb']}МБ');
    } else {
      AppLogger.log('[СТАТУС] $ip: '
          '${(adbOnline || httpAvailable) ? "online но health недоступен (http=$httpAvailable adb=$adbOnline)" : "ОФЛАЙН (не отвечает 5011/ADB)"}');
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
      playbackEnabled: health?['playbackEnabled'] as bool?,
      currentClip: health?['current'] as String?,
      deviceOwner: health?['deviceOwner'] as bool?,
      signature: health?['signature'] as String?,
      canInstall: health?['canInstall'] as bool?,
      batteryExempt: health?['batteryExempt'] as bool?,
      overlay: health?['overlay'] as bool?,
      deviceId: health?['deviceId'] as String?,
      protocolVersion: health?['protocolVersion'] as int?,
      activeDeploymentId: health?['activeDeploymentId'] as String?,
      playlistHash: health?['playlistHash'] as String?,
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

  // Проверяет все IP параллельно (батчами, чтобы не забивать WiFi/ADB).
  // [onResult] вызывается для КАЖДОГО устройства сразу, как его статус готов —
  // UI может показывать планшеты по мере обнаружения, не дожидаясь всех.
  Future<List<DeviceStatus>> checkAll(
    List<String> ips, {
    void Function(DeviceStatus status)? onResult,
  }) async {
    if (ips.isEmpty) return [];
    final results = <DeviceStatus>[];
    // Снимок `adb devices` один раз на всю проверку — раньше каждый
    // checkDevice снимал его заново.
    final known = await _listAdbDevices();
    const batchSize = 3;
    for (var i = 0; i < ips.length; i += batchSize) {
      final batch = ips.skip(i).take(batchSize);
      await Future.wait(batch.map((ip) async {
        final status = await checkDevice(ip, knownDevices: known);
        results.add(status);
        onResult?.call(status);
        return status;
      }));
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

  Future<bool> enablePlayback(String ip) async {
    final client = DeviceHttp(ip);
    // launch атомарно меняет desired-state до поднятия Activity и сам будит
    // экран. Отдельный wake при выключенной рекламе создавал гонку: Activity
    // успевала запланировать lockNow() до следующей команды launch.
    return client.launch();
  }

  Future<bool> disablePlayback(String ip) async {
    final client = DeviceHttp(ip);
    if (await client.stopPlayback()) return true;
    // Legacy fallback: старый APK не знает desired-state, хотя бы гасим экран.
    await sleep(ip);
    return false;
  }

  Future<void> bulkEnablePlayback(Iterable<String> ips) async {
    await Future.wait(ips.map(enablePlayback));
  }

  Future<void> bulkDisablePlayback(Iterable<String> ips) async {
    await Future.wait(ips.map(disablePlayback));
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
      () =>
          _run(adb, ['-s', id, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']),
      _ok,
    );
    await _run(adb, ['-s', id, 'shell', 'wm', 'dismiss-keyguard']);
    if (launchPlayer) {
      await _run(
          adb, ['-s', id, 'shell', 'am', 'force-stop', 'com.brandmen.ads'],
          timeout: const Duration(seconds: 4));
      await _run(
          adb,
          [
            '-s',
            id,
            'shell',
            'monkey',
            '-p',
            'com.brandmen.ads',
            '-c',
            'android.intent.category.LAUNCHER',
            '1'
          ],
          timeout: const Duration(seconds: 6));
    }
  }

  /// Проверяет, что плеер РЕАЛЬНО играет, а не просто принял команду запуска.
  /// На HyperOS HTTP-launch может вернуть ok, но видео не выйдет на экран —
  /// поэтому опрашиваем /api/control/now несколько раз и ждём playing=true.
  ///
  /// ВАЖНО: сразу после launch плеер на 10–30 с роняет свой HTTP-сервер
  /// (controlNow → connection refused / timeout). Старое окно в ~5 с не
  /// дожидалось возврата сервера и давало ЛОЖНОЕ «не играет», хотя планшет
  /// играет. Поэтому ждём дольше (до ~30 с) и терпим отказы подключения как
  /// «сервер ещё перезапускается». Если же сервер ответил, но playing=false
  /// несколько раз подряд — это уже настоящая проблема, выходим раньше.
  Future<bool> verifyPlaying(String ip, {int attempts = 30}) async {
    final client = DeviceHttp(ip);
    int connectedNotPlaying = 0;
    for (int i = 0; i < attempts; i++) {
      await Future.delayed(const Duration(seconds: 1));
      final now = await client.controlNow();
      if (now == null) {
        // Сервер недоступен (перезапускается после launch) — ждём дальше.
        continue;
      }
      if (now['playing'] == true) {
        AppLogger.log('verifyPlaying $ip: играет (попытка ${i + 1})');
        return true;
      }
      // Сервер отвечает, но не играет — даём несколько шансов (загрузка
      // первого ролика), затем считаем, что реально не играет.
      if (++connectedNotPlaying >= 8) {
        AppLogger.log('verifyPlaying $ip: сервер отвечает, но НЕ играет '
            '($connectedNotPlaying проверок) — реальная проблема');
        return false;
      }
    }
    AppLogger.log('verifyPlaying $ip: НЕ играет после $attempts попыток '
        '(возможно сервер не вернулся после launch)');
    return false;
  }

  /// Проверяет не просто воспроизведение, а применение конкретного deployment.
  /// Две разные позиции защищают от зависшего первого кадра.
  Future<bool> verifyDeploymentPlaying(
    String ip, {
    required String deploymentId,
    required String playlistHash,
    int attempts = 30,
  }) async {
    final client = DeviceHttp(ip);
    int? lastPosition;
    for (int i = 0; i < attempts; i++) {
      await Future.delayed(const Duration(seconds: 1));
      final health = await client.health();
      if (health == null ||
          health['activeDeploymentId'] != deploymentId ||
          health['playlistHash'] != playlistHash ||
          health['playing'] != true ||
          (health['currentFileSha256'] as String? ?? '').isEmpty) {
        continue;
      }
      final position = health['positionMs'] as int? ?? -1;
      if (lastPosition != null && position >= 0 && position != lastPosition) {
        AppLogger.log('verifyDeployment $ip: deployment=$deploymentId играет');
        return true;
      }
      lastPosition = position;
    }
    AppLogger.log('verifyDeployment $ip: deployment=$deploymentId '
        'не подтверждён');
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
    // После перекодирования нельзя полагаться на совпадение размера: новый
    // H.264-файл теоретически может иметь тот же размер, но другое содержимое.
    // В этом режиме отправляем весь актуальный набор на каждый планшет.
    bool forceUpload = false,
    ContentDeployment? deployment,
    // Фоновое desired-state не имеет права незаметно откатываться на legacy:
    // legacy не выставляет activeDeploymentId, и иначе синк повторяется вечно.
    bool requireDeploymentV2 = false,
  }) async {
    final httpOk = tryHttpFirst && await DeviceHttp.isAvailable(ip);
    if (httpOk) {
      final client = DeviceHttp(ip);
      final capabilities = await client.deploymentCapabilities();
      if ((capabilities?['protocol_version'] as num?)?.toInt() == 2) {
        AppLogger.log('Sync $ip: использую deployment protocol v2');
        final prepared =
            deployment ?? await DeploymentBuilder.fromMediaDirectory(localDir);
        return _syncViaDeployment(
          ip,
          localDir,
          prepared,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      }
      if (requireDeploymentV2) {
        return const SyncResult(
          success: false,
          pushed: [],
          transport: 'Deployment v2',
          error: 'Защищённая синхронизация недоступна — повторите сопряжение',
        );
      }
      AppLogger.log('Sync $ip: используем HTTP (порт 5011)');
      final httpResult = await _syncViaHttp(ip, localDir,
          onProgress: onProgress,
          isCancelled: isCancelled,
          forceUpload: forceUpload);
      if (httpResult.success) return httpResult;

      // Пользователь нажал «Отмена» — не уходим в ADB-фолбэк.
      if (isCancelled?.call() ?? false) return httpResult;

      AppLogger.log(
          'Sync $ip: HTTP не завершился, пробую ADB fallback: ${httpResult.error}');
      final adbResult = await _syncViaAdb(ip, localDir,
          onProgress: onProgress, forceUpload: forceUpload);
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
    return _syncViaAdb(ip, localDir,
        onProgress: onProgress, forceUpload: forceUpload);
  }

  Future<SyncResult> _syncViaDeployment(
    String ip,
    String localDir,
    ContentDeployment deployment, {
    void Function(int done, int total, String filename)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = DeviceHttp(ip);
    final operationId =
        '${DateTime.now().microsecondsSinceEpoch}-${deployment.deploymentId.substring(0, 8)}';
    final stopwatch = Stopwatch()..start();
    OperationEvent.log(
      event: 'deployment_prepare',
      device: ip,
      operationId: operationId,
      deploymentId: deployment.deploymentId,
      from: 'current',
      to: 'preparing',
    );
    final prepared = await client.prepareDeployment(deployment);
    if (prepared == null) {
      OperationEvent.log(
        event: 'deployment_failed',
        device: ip,
        operationId: operationId,
        deploymentId: deployment.deploymentId,
        from: 'preparing',
        to: 'failed',
        errorCode: 'prepare_failed',
        durationMs: stopwatch.elapsedMilliseconds,
      );
      return const SyncResult(
        success: false,
        pushed: [],
        transport: 'Deployment v2',
        error: 'Планшет не подготовил новую версию контента',
      );
    }

    final missing = ((prepared['missing'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();
    final partialRaw =
        (prepared['partial'] as Map?)?.cast<String, dynamic>() ?? const {};
    final byHash = {for (final file in deployment.files) file.sha256: file};
    final pushed = <String>[];
    var completed = deployment.files.length - missing.length;

    for (final hash in missing) {
      if (isCancelled?.call() ?? false) {
        return SyncResult(
          success: false,
          pushed: pushed,
          transport: 'Deployment v2',
          error: 'Отменено',
        );
      }
      final descriptor = byHash[hash];
      if (descriptor == null) {
        return SyncResult(
          success: false,
          pushed: pushed,
          transport: 'Deployment v2',
          error: 'Manifest содержит неизвестный SHA-256',
        );
      }
      final source = File(p.join(localDir, descriptor.logicalName));
      final offset = (partialRaw[hash] as num?)?.toInt() ?? 0;
      onProgress?.call(
          completed, deployment.files.length, descriptor.logicalName);
      final result = await client.uploadDeploymentBlob(
        descriptor,
        source,
        offset: offset,
      );
      if (result == null || result['complete'] != true) {
        OperationEvent.log(
          event: 'deployment_failed',
          device: ip,
          operationId: operationId,
          deploymentId: deployment.deploymentId,
          from: 'uploading',
          to: 'failed',
          errorCode: 'blob_verification_failed',
          durationMs: stopwatch.elapsedMilliseconds,
        );
        return SyncResult(
          success: false,
          pushed: pushed,
          transport: 'Deployment v2',
          error: 'Не удалось проверить ${descriptor.logicalName}',
        );
      }
      pushed.add(descriptor.logicalName);
      OperationEvent.log(
        event: 'blob_verified',
        device: ip,
        operationId: operationId,
        deploymentId: deployment.deploymentId,
        from: 'uploading',
        to: 'verifying',
        bytesTransferred: descriptor.size - offset,
      );
      completed++;
      onProgress?.call(
          completed, deployment.files.length, descriptor.logicalName);
    }

    final commit = await client.commitDeployment(deployment.deploymentId);
    if (commit == null ||
        commit['active_deployment_id'] != deployment.deploymentId) {
      OperationEvent.log(
        event: 'deployment_failed',
        device: ip,
        operationId: operationId,
        deploymentId: deployment.deploymentId,
        from: 'activating',
        to: 'failed',
        errorCode: 'commit_not_confirmed',
        durationMs: stopwatch.elapsedMilliseconds,
      );
      return SyncResult(
        success: false,
        pushed: pushed,
        transport: 'Deployment v2',
        error: 'Планшет не активировал новую версию контента',
      );
    }
    onProgress?.call(deployment.files.length, deployment.files.length, '');
    OperationEvent.log(
      event: 'deployment_committed',
      device: ip,
      operationId: operationId,
      deploymentId: deployment.deploymentId,
      from: 'activating',
      to: 'validating',
      durationMs: stopwatch.elapsedMilliseconds,
    );
    return SyncResult(
      success: true,
      pushed: pushed,
      transport: 'Deployment v2',
    );
  }

  Future<SyncResult> _syncViaHttp(
    String ip,
    String localDir, {
    void Function(int done, int total, String filename)? onProgress,
    bool Function()? isCancelled,
    required bool forceUpload,
  }) async {
    final client = DeviceHttp(ip);
    // Планшет, который был офлайн в момент смены бренда, получит актуальный
    // пакет при первой же успешной Wi‑Fi синхронизации. На старом плеере
    // endpoint отсутствует — это не мешает обычной передаче роликов.
    if (!await client.applyBrandPack(BrandPacks.current.value)) {
      AppLogger.log('HTTP sync $ip: бренд-пакет пока не применён');
    }
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

    final allLocal = localFolder.listSync().whereType<File>().toList();
    final allLocalNames = allLocal.map((f) => p.basename(f.path)).toSet();
    final localFiles = allLocal.where((f) {
      final name = p.basename(f.path);
      final lower = name.toLowerCase();
      if (lower.startsWith('.')) return false;
      // Исходник заменён сконвертированным mp4 — не отправляем его.
      if (Transcoder.hasMp4TwinIn(allLocalNames, name)) return false;
      return lower == 'playlist.m3u' || isVideoFile(lower);
    }).toList();
    // Плейлист публикуем последним: он не должен ссылаться на ролики, которые
    // ещё находятся в пути. Имена дополнительно стабилизируют порядок лога.
    localFiles.sort((a, b) {
      final aPlaylist = p.basename(a.path).toLowerCase() == 'playlist.m3u';
      final bPlaylist = p.basename(b.path).toLowerCase() == 'playlist.m3u';
      if (aPlaylist != bPlaylist) return aPlaylist ? 1 : -1;
      return p.basename(a.path).compareTo(p.basename(b.path));
    });

    // Проверка свободного места на планшете перед заливкой: считаем, сколько
    // байт реально нужно докачать, и сверяем с /health (запас 50 МБ).
    int needBytes = 0;
    for (final f in localFiles) {
      final name = p.basename(f.path);
      final isPlaylist = name.toLowerCase() == 'playlist.m3u';
      final sz = await f.length();
      if (forceUpload || isPlaylist || remoteFiles[name] != sz) {
        needBytes += sz;
      }
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
              success: false,
              pushed: pushed,
              error: 'Отменено',
              transport: 'HTTP');
        }
        final f = localFiles[i];
        final name = p.basename(f.path);
        final isPlaylist = name.toLowerCase() == 'playlist.m3u';
        final localSize = await f.length();

        onProgress?.call(i, localFiles.length, name);

        if (!forceUpload && !isPlaylist && remoteFiles[name] == localSize) {
          continue;
        }

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
    required bool forceUpload,
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

    final allLocal = localFolder.listSync().whereType<File>().toList();
    final allLocalNames = allLocal.map((f) => p.basename(f.path)).toSet();
    final localFiles = allLocal.where((f) {
      final name = p.basename(f.path);
      final lower = name.toLowerCase();
      if (lower.startsWith('.')) return false;
      // Исходник заменён сконвертированным mp4 — не отправляем его.
      if (Transcoder.hasMp4TwinIn(allLocalNames, name)) return false;
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
      if (!forceUpload && !isPlaylist && remoteSizes[name] == localSize) {
        continue;
      }

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

    // Как и в HTTP-ветке, чистим старые файлы только после полностью успешной
    // загрузки. Иначе можно удалить рабочий ролик, пока его замена не дошла.
    if (failed.isEmpty) {
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
    } else {
      AppLogger.log("Sync $ip: были ошибки push — пропускаю удаление "
          "старых файлов, чтобы сохранить рабочий контент");
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
      () =>
          _run(adb, ['-s', id, 'shell', 'input', 'keyevent', 'KEYCODE_SLEEP']),
      _ok,
      attempts: 2,
    );
  }

  /// Чинит доступ по ADB: выдаёт app-op (разрешение «Установка неизвестных
  /// приложений» / «Поверх других приложений») или вносит плеер в whitelist
  /// оптимизации батареи. Возвращает успех и вывод устройства.
  Future<({bool ok, String output})> fixAccess(String ip, String fix) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    const pkg = 'com.brandmen.ads';
    final List<String> shellCmd;
    switch (fix) {
      case 'canInstall':
        shellCmd = ['appops', 'set', pkg, 'REQUEST_INSTALL_PACKAGES', 'allow'];
        break;
      case 'overlay':
        shellCmd = ['appops', 'set', pkg, 'SYSTEM_ALERT_WINDOW', 'allow'];
        break;
      case 'batteryExempt':
        shellCmd = ['dumpsys', 'deviceidle', 'whitelist', '+$pkg'];
        break;
      default:
        return (ok: false, output: 'неизвестный фикс: $fix');
    }
    await _retry(
      'ADB connect $ip',
      () => _run(adb, ['connect', id], timeout: const Duration(seconds: 4)),
      _ok,
      attempts: 2,
    );
    final r = await _run(adb, ['-s', id, 'shell', ...shellCmd],
        timeout: const Duration(seconds: 8));
    final out = '${r.stdout}${r.stderr}'.trim();
    final ok = r.exitCode == 0 &&
        !out.toLowerCase().contains('error') &&
        !out.toLowerCase().contains('exception');
    AppLogger.log('[ДОСТУП] $fix → $ip: ${ok ? "OK" : "ошибка"} '
        '${out.isEmpty ? "" : "($out)"}');
    return (ok: ok, output: out.isEmpty ? 'выполнено' : out);
  }

  /// Делает плеер device owner — тогда обновления ставятся молча.
  /// Требует ADB (USB или сеть) и отсутствия аккаунтов на планшете, иначе
  /// dpm вернёт ошибку (нужен factory reset). Возвращает успех и вывод команды.
  Future<({bool ok, String output})> setDeviceOwner(String ip) async {
    final adb = await _getAdb();
    final id = '$ip:5555';
    await _retry(
      'ADB connect $ip',
      () => _run(adb, ['connect', id], timeout: const Duration(seconds: 4)),
      _ok,
      attempts: 2,
    );
    return _setDeviceOwnerTarget('$ip:5555');
  }

  /// Назначает owner на уже подключённом ADB-устройстве (IP или USB serial).
  /// Вынесено отдельно: при первичной подготовке это надо сделать по USB,
  /// *до* включения ADB по сети. Android разрешает назначить Device Owner
  /// только на чистом устройстве, поэтому эта операция никогда не маскирует
  /// отказ как «частично настроено».
  Future<({bool ok, String output})> _setDeviceOwnerTarget(
      String target) async {
    final adb = await _getAdb();
    final r = await _run(
      adb,
      [
        '-s',
        target,
        'shell',
        'dpm',
        'set-device-owner',
        'com.brandmen.ads/com.brandmen.ads.DeviceAdminReceiver'
      ],
      timeout: const Duration(seconds: 10),
    );
    final out = '${r.stdout}${r.stderr}'.trim();
    if (r.exitCode != 0 || !out.toLowerCase().contains('success')) {
      return (
        ok: false,
        output: out.isEmpty ? 'нет вывода от устройства' : out
      );
    }

    // Ответ dpm «Success» — ещё не достаточное доказательство: сразу читаем
    // реального владельца политики и не показываем готовность, пока не увидим
    // именно наш пакет.
    final check = await _run(
        adb, ['-s', target, 'shell', 'dpm', 'get-device-owner'],
        timeout: const Duration(seconds: 6));
    final verified =
        '${check.stdout}${check.stderr}'.contains('com.brandmen.ads');
    return (
      ok: verified,
      output: verified
          ? 'Device Owner назначен и подтверждён устройством'
          : '$out\nНе удалось подтвердить статус Device Owner'
    );
  }

  Future<void> setVolume(String ip, int level) async {
    if (await DeviceHttp(ip).setVolumeHttp(level)) return;
    AppLogger.log(
        '[КОМАНДА] громкость=$level → $ip: HTTP не прошёл, пробую ADB');
    // ADB fallback
    final adb = await _getAdb();
    final id = '$ip:5555';
    await _run(adb, [
      '-s',
      id,
      'shell',
      'cmd',
      'media_session',
      'volume',
      '--stream',
      '3',
      '--set',
      '${level.clamp(0, 15)}',
      '--show'
    ]);
  }

  Future<int> getVolume(String ip) async {
    final status = await DeviceHttp(ip).controlStatus();
    if (status != null) return status['volume']!;
    // ADB fallback
    final adb = await _getAdb();
    final id = '$ip:5555';
    final r = await _run(
        adb,
        [
          '-s',
          id,
          'shell',
          'cmd',
          'media_session',
          'volume',
          '--stream',
          '3',
          '--get'
        ],
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
    AppLogger.log('[КОМАНДА] яркость=$level → $ip: HTTP не прошёл, пробую ADB');
    // ADB fallback
    final adb = await _getAdb();
    final id = '$ip:5555';
    await _run(adb, [
      '-s',
      id,
      'shell',
      'settings',
      'put',
      'system',
      'screen_brightness_mode',
      '0'
    ]);
    await _run(adb, [
      '-s',
      id,
      'shell',
      'settings',
      'put',
      'system',
      'screen_brightness',
      '${level.clamp(1, 255)}'
    ]);
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

  // Регистрация: получает IP USB-планшета, при необходимости назначает
  // Device Owner, включает TCP и возвращает IP. Device Owner делаем именно
  // по USB: после factory reset Wi-Fi ADB ещё не настроен.
  Future<
          ({
            String? ip,
            bool ownerReady,
            bool adbReady,
            bool adbPersistent,
            String message
          })>
      registerViaUsb(String usbDeviceId, {bool makeDeviceOwner = false}) async {
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
        return (
          ip: null,
          ownerReady: false,
          adbReady: false,
          adbPersistent: false,
          message: 'не удалось определить IP'
        );
      }

      var ownerReady = false;
      var message = '';
      if (makeDeviceOwner) {
        AppLogger.log('USB ($usbDeviceId): назначаю Device Owner...');
        final owner = await _setDeviceOwnerTarget(usbDeviceId);
        if (!owner.ok) {
          // Не включаем сетевое ADB как будто планшет подготовлен: оператор
          // сразу получает ясный результат и может сбросить устройство.
          return (
            ip: ip,
            ownerReady: false,
            adbReady: false,
            adbPersistent: false,
            message: owner.output
          );
        }
        ownerReady = true;
        message = owner.output;
      }

      final keyboardNote = await _ensureInputMethod(usbDeviceId);
      if (keyboardNote.isNotEmpty) {
        message = [message, keyboardNote]
            .where((part) => part.trim().isNotEmpty)
            .join(' ');
      }

      AppLogger.log(
          "USB ($usbDeviceId): IP=$ip, включаем постоянный TCP/IP...");
      await _run(adb, [
        '-s',
        usbDeviceId,
        'shell',
        'settings',
        'put',
        'global',
        'adb_enabled',
        '1'
      ]);
      await _run(adb, [
        '-s',
        usbDeviceId,
        'shell',
        'setprop',
        'persist.adb.tcp.port',
        '5555'
      ]);
      final persistentResult = await _run(
          adb, ['-s', usbDeviceId, 'shell', 'getprop', 'persist.adb.tcp.port']);
      final adbPersistent = persistentResult.stdout.toString().trim() == '5555';

      final tcpResult = await _run(adb, ['-s', usbDeviceId, 'tcpip', '5555'],
          timeout: const Duration(seconds: 6));
      await Future.delayed(const Duration(seconds: 2));
      final connectResult = await _run(adb, ['connect', '$ip:5555'],
          timeout: const Duration(seconds: 5));
      final stateResult = await _run(adb, ['-s', '$ip:5555', 'get-state'],
          timeout: const Duration(seconds: 4));
      final adbReady = stateResult.exitCode == 0 &&
          stateResult.stdout.toString().trim() == 'device';
      final tcpOutput =
          '${tcpResult.stdout}${tcpResult.stderr}${connectResult.stdout}${connectResult.stderr}'
              .trim();
      final persistenceNote = adbPersistent
          ? 'ADB по Wi‑Fi сохранён после перезагрузки.'
          : 'Прошивка не разрешила сохранить ADB после перезагрузки; '
              'основное управление продолжит работать через Brandmen HTTP.';
      message = [message, persistenceNote, if (!adbReady) tcpOutput]
          .where((part) => part.trim().isNotEmpty)
          .join(' ');
      AppLogger.log("USB: $ip:5555 ready=$adbReady persistent=$adbPersistent");
      return (
        ip: ip,
        ownerReady: ownerReady,
        adbReady: adbReady,
        adbPersistent: adbPersistent,
        message: message
      );
    } catch (e) {
      AppLogger.log("Ошибка USB регистрации ($usbDeviceId): $e");
      return (
        ip: null,
        ownerReady: false,
        adbReady: false,
        adbPersistent: false,
        message: '$e'
      );
    }
  }

  /// Xiaomi иногда оставляет enabled_input_methods со ссылками на удалённые
  /// китайские клавиатуры. Тогда поле ввода получает фокус, но IME не
  /// появляется. Во время USB-подготовки выбираем реально установленную IME.
  Future<String> _ensureInputMethod(String deviceId) async {
    final adb = await _getAdb();
    final availableResult = await _run(
      adb,
      ['-s', deviceId, 'shell', 'ime', 'list', '-s'],
      timeout: const Duration(seconds: 5),
    );
    final available = availableResult.stdout
        .toString()
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.contains('/'))
        .toList();
    if (available.isEmpty) {
      AppLogger.log('USB ($deviceId): на планшете нет доступной клавиатуры');
      return 'Клавиатура не найдена — установите её на планшет.';
    }

    final currentResult = await _run(adb, [
      '-s',
      deviceId,
      'shell',
      'settings',
      'get',
      'secure',
      'default_input_method'
    ]);
    final current = currentResult.stdout.toString().trim();
    if (current.isNotEmpty &&
        current != 'null' &&
        available.contains(current)) {
      return '';
    }

    String selected = available.first;
    for (final preferred in const [
      'com.menny.android.anysoftkeyboard/.SoftKeyboard',
      'com.miui.securityinputmethod/.latin.LatinIME',
    ]) {
      if (available.contains(preferred)) {
        selected = preferred;
        break;
      }
    }
    await _run(adb, ['-s', deviceId, 'shell', 'ime', 'enable', selected]);
    final setResult =
        await _run(adb, ['-s', deviceId, 'shell', 'ime', 'set', selected]);
    if (setResult.exitCode == 0) {
      AppLogger.log('USB ($deviceId): клавиатура восстановлена ($selected)');
      return 'Клавиатура восстановлена.';
    }
    AppLogger.log('USB ($deviceId): не удалось выбрать клавиатуру: '
        '${setResult.stdout}${setResult.stderr}');
    return 'Не удалось включить экранную клавиатуру.';
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
  Future<ApkInstallResult> installApk(String ip, String apkPath,
      {String? targetVersion}) async {
    // 0. Сначала пробуем по HTTP (порт 5011) — тот же надёжный канал, что и
    // синк, работает без ADB. Плеер сам покажет окно установки поверх себя.
    try {
      final apk = File(apkPath);
      final healthBefore = await DeviceHttp(ip).health();
      final silentExpected = healthBefore?['deviceOwner'] == true;
      if (await apk.exists() && await DeviceHttp(ip).installApkHttp(apk)) {
        // HTTP 200 подтверждает только приём APK. На Device Owner установка
        // тихая и асинхронная: ждём перезапуска плеера и новой /version, чтобы
        // Windows не сообщал ложный успех и не отправлял APK повторно.
        if (silentExpected && targetVersion != null) {
          for (var attempt = 0; attempt < 15; attempt++) {
            await Future<void>.delayed(const Duration(seconds: 1));
            final installedVersion = await getApkVersion(ip);
            if (installedVersion == targetVersion) {
              AppLogger.log('installApk $ip: подтверждена v$targetVersion');
              return ApkInstallResult.installed;
            }
          }
          AppLogger.log('installApk $ip: APK принят, но v$targetVersion '
              'ещё не подтверждена');
        } else {
          AppLogger.log(
              'installApk $ip: доставлен по HTTP, ожидается подтверждение на планшете');
        }
        return ApkInstallResult.dialogShown;
      }
      AppLogger.log('installApk $ip: HTTP-установка недоступна, пробую ADB');
    } catch (e) {
      AppLogger.log('installApk $ip: HTTP-установка ошибка $e, пробую ADB');
    }

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

    // 3. Тихая установка не прошла (не device owner / запрещено политикой) —
    // запускаем СИСТЕМНЫЙ установщик на экране планшета через ADB. Окно
    // «Установить обновление?» появляется поверх плеера; человеку остаётся
    // один тап, без проводника и поиска файла в «Загрузках».
    if (pushOk) {
      AppLogger.log(
          'installApk $ip: запускаю системный установщик на экране планшета');
      final am = await _run(
          adb,
          [
            '-s',
            id,
            'shell',
            'am',
            'start',
            '-a',
            'android.intent.action.VIEW',
            '-d',
            'file:///sdcard/Download/BrandmenAds.apk',
            '-t',
            'application/vnd.android.package-archive',
          ],
          timeout: const Duration(seconds: 10));
      final amOut = (am.stdout.toString() + am.stderr.toString()).toLowerCase();
      final shown = am.exitCode == 0 &&
          !amOut.contains('error') &&
          !amOut.contains('exception');
      if (shown) {
        AppLogger.log(
            'installApk $ip: окно установки открыто на планшете (ADB)');
        return ApkInstallResult.dialogShown;
      }
      AppLogger.log(
          'installApk $ip: установщик не открылся ($amOut) — файл в «Загрузках»');
    }

    return pushOk
        ? ApkInstallResult.pushedToDownloads
        : ApkInstallResult.failed;
  }

  Future<String?> takeScreenshot(String ip, String savePath) async {
    // Сначала HTTP (если плеер поддерживает /api/control/screenshot) — один
    // запрос вместо трёх ADB-команд, и превью работает у HTTP-only планшетов.
    final png = await DeviceHttp(ip).screenshotPng();
    if (png != null) {
      try {
        await File(savePath).writeAsBytes(png);
        return savePath;
      } catch (e) {
        AppLogger.log("Скриншот $ip: не удалось сохранить ($e), пробую ADB");
      }
    }
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
