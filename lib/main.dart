import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:desktop_drop/desktop_drop.dart';

import 'server.dart';
import 'discovery.dart';
import 'adb_manager.dart';
import 'device_http.dart';
import 'logger.dart';
import 'tray_manager.dart';
import 'device_storage.dart';
import 'media_config.dart';
import 'transcoder.dart';
import 'backup_manager.dart';
import 'autostart.dart';
import 'updater.dart';
import 'log_uploader.dart';
import 'brand_pack.dart';
import 'brand_pack_screen.dart';
import 'deployment.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();
  await AppSettings.load();
  await BrandPacks.load();
  await _startServer();
  _startLogAutoUpload();
  _startFleetSnapshotUpload();
  runApp(const BrandmenApp());
}

/// Передаёт в удалённую панель тот же список планшетов, который сохранён в
/// Windows/macOS. Это только инвентаризация: секреты локального сопряжения не
/// покидают компьютер.
void _startFleetSnapshotUpload() {
  Future<void> tick() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final urlPref =
          (prefs.getString(_SettingsScreenState.kLogServerUrlKey) ?? '').trim();
      final tokenPref =
          (prefs.getString(_SettingsScreenState.kLogServerTokenKey) ?? '')
              .trim();
      final devices = await DeviceStorage.load();
      final ok = await LogUploader.sendFleetSnapshot(
        baseUrl: effectiveLogServerUrl(urlPref),
        token: tokenPref.isEmpty ? kDefaultLogServerToken : tokenPref,
        devices: devices
            .map((d) => {
                  'ip': d.ip,
                  'name': d.name,
                  if (d.deviceId != null) 'device_id': d.deviceId,
                  if (d.desiredDeploymentId != null)
                    'desired_deployment_id': d.desiredDeploymentId,
                })
            .toList(),
      );
      if (!ok) AppLogger.log('[FLEET] не удалось обновить удалённую панель');
    } catch (e) {
      AppLogger.log('[FLEET] ошибка отправки списка экранов: $e');
    }
  }

  Timer(const Duration(seconds: 20), tick);
  Timer.periodic(const Duration(minutes: 1), (_) => tick());
}

/// Автоотправка лога на сервер — чтобы каждый ПК сам появлялся на дашборде и
/// слал диагностику без ручного нажатия ☆. Адрес/токен берём из Настроек, а
/// если там пусто — зашитые по умолчанию (kDefaultLogServerUrl/Token).
/// Первая отправка вскоре после старта, затем периодически.
void _startLogAutoUpload() {
  Future<void> tick() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final urlPref =
          (prefs.getString(_SettingsScreenState.kLogServerUrlKey) ?? '').trim();
      final tokenPref =
          (prefs.getString(_SettingsScreenState.kLogServerTokenKey) ?? '')
              .trim();
      final url = effectiveLogServerUrl(urlPref);
      final token = tokenPref.isEmpty ? kDefaultLogServerToken : tokenPref;
      if (url.isEmpty) return;
      final res = await LogUploader.send(baseUrl: url, token: token);
      if (!res.ok) {
        AppLogger.log('[LOG-AUTO] отправка не удалась: ${res.message}');
      }
    } catch (e) {
      AppLogger.log('[LOG-AUTO] ошибка автоотправки: $e');
    }
  }

  // ПК должен появиться на дашборде вскоре после запуска.
  Timer(const Duration(seconds: 45), tick);
  // Дальше — регулярно, для мониторинга «жив/что со связью».
  Timer.periodic(const Duration(minutes: 15), (_) => tick());

  // Живой поток: раз в 3 с отправляем накопившиеся новые строки лога на
  // {URL}/live — почти реальное время для отладки. Если строк нет — молчим.
  bool busy = false;
  Timer.periodic(const Duration(seconds: 3), (_) async {
    if (busy) return;
    final lines = AppLogger.drainPending();
    if (lines.isEmpty) return;
    busy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final urlPref =
          (prefs.getString(_SettingsScreenState.kLogServerUrlKey) ?? '').trim();
      final tokenPref =
          (prefs.getString(_SettingsScreenState.kLogServerTokenKey) ?? '')
              .trim();
      final url = effectiveLogServerUrl(urlPref);
      final token = tokenPref.isEmpty ? kDefaultLogServerToken : tokenPref;
      final ok =
          await LogUploader.sendLive(baseUrl: url, token: token, lines: lines);
      if (!ok) AppLogger.requeuePending(lines); // вернём, попробуем позже
    } catch (_) {
      AppLogger.requeuePending(lines);
    } finally {
      busy = false;
    }
  });
}

/// Глобальные UI-настройки, на которые экраны реагируют вживую.
class AppSettings {
  /// Показывать бейдж «не ставит обновления сам» на карточках планшетов,
  /// которые не являются device owner. Можно выключить в Настройках, когда все
  /// планшеты провижинены — чтобы бейджи не мозолили глаза.
  static final ValueNotifier<bool> showAutoUpdateBadge = ValueNotifier(true);

  static const _kBadgeKey = 'show_auto_update_badge';

  /// Режим разработчика: показывает техническое управление (ребут, статусы,
  /// диагностика). Для персонала выключен — интерфейс остаётся простым.
  static final ValueNotifier<bool> developerMode = ValueNotifier(false);

  static const _kDevKey = 'developer_mode';

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    showAutoUpdateBadge.value = prefs.getBool(_kBadgeKey) ?? true;
    developerMode.value = prefs.getBool(_kDevKey) ?? false;
  }

  static Future<void> setShowAutoUpdateBadge(bool value) async {
    showAutoUpdateBadge.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBadgeKey, value);
  }

  static Future<void> setDeveloperMode(bool value) async {
    developerMode.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDevKey, value);
  }
}

Future<void> _startServer() async {
  try {
    await MediaConfig.resolveDir();
    BrandmenServer.instance = BrandmenServer();
    await BrandmenServer.instance!.start();
    AppLogger.log(
        "HTTP сервер запущен на порту 5010, папка: ${MediaConfig.current}");
  } catch (e) {
    AppLogger.log("Ошибка запуска сервера: $e");
  }
  DiscoveryBeacon().start();
}

class BrandmenApp extends StatelessWidget {
  const BrandmenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BrandPack>(
      valueListenable: BrandPacks.current,
      builder: (_, pack, __) => MaterialApp(
        title: '${pack.name} Control',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'Segoe UI',
          colorScheme: ColorScheme.dark(
            primary: pack.accent,
            surface: const Color(0xFF17171A),
          ),
          scaffoldBackgroundColor: Colors.transparent,
          dividerColor: Colors.white10,
          snackBarTheme: const SnackBarThemeData(
            backgroundColor: Color(0xFF26262A),
            contentTextStyle: TextStyle(color: Colors.white),
            behavior: SnackBarBehavior.floating,
          ),
          dialogTheme: DialogThemeData(
            backgroundColor: const Color(0xFF202024),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          useMaterial3: true,
        ),
        home: AppleBackgroundWrapper(child: MainScreen(), accent: pack.accent),
      ),
    );
  }
}

class AppleBackgroundWrapper extends StatelessWidget {
  final Widget child;
  final Color accent;
  const AppleBackgroundWrapper(
      {super.key, required this.child, this.accent = Colors.blue});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
                accent.withValues(alpha: .16), const Color(0xFF2C2C2E)),
            const Color(0xFF121215)
          ],
        ),
      ),
      child: child,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const _adminPin = '2468';
  int _selectedIndex = 0;
  bool _adminMode = false;
  Timer? _adminModeTimer;
  Timer? _schedulerTimer;
  Timer? _updateTimer;
  bool _checkingForUpdate = false;
  bool _updateDialogVisible = false;
  String? _lastTriggerMinute;
  final adb = AdbManager();
  final tray = TrayManager();
  StreamSubscription<DeviceRegistration>? _regSub;
  final _settingsKey = GlobalKey<_SettingsScreenState>();
  final _dashboardKey = GlobalKey<_DashboardScreenState>();

  /// Открывает файл лога в проводнике/Finder, чтобы посмотреть, что происходит
  /// (в т.ч. подробности проверки обновлений — строки [UPD]).
  Future<void> _openLog() async {
    final path = AppLogger.logPath;
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Лог-файл ещё не создан")));
      }
      return;
    }
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,$path']);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else {
        await Process.run('xdg-open', [File(path).parent.path]);
      }
    } catch (e) {
      AppLogger.log('Открыть лог: $e');
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Лог: $path"), duration: const Duration(seconds: 6)));
    }
  }

  @override
  void initState() {
    super.initState();
    _startScheduler();
    _cleanupOnStart();
    tray.init(() {
      if (mounted) setState(() {});
    });
    _checkForUpdate(delay: const Duration(seconds: 5));
    _updateTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => _checkForUpdate(),
    );
    _regSub =
        BrandmenServer.instance?.onDeviceRegistered.listen(_onDeviceRegistered);
  }

  Future<void> _onDeviceRegistered(DeviceRegistration reg) async {
    await DeviceStorage.add(
      reg.ip,
      name: reg.name,
      deviceId: reg.deviceId,
      apiToken: reg.apiToken,
    );
    DeviceHttp.registerToken(reg.ip, reg.apiToken);
    // SettingsScreen живёт внутри IndexedStack и раньше сохранял снимок списка
    // с момента запуска. После смены Wi‑Fi Dashboard уже видел новый IP, а
    // админская кнопка обновления APK продолжала обращаться к старому адресу.
    await _settingsKey.currentState?._loadDevices();
    if (!reg.isReconnect) {
      BrandmenServer.instance?.stopPairing();
      _settingsKey.currentState?._stopPairing();
    }
    // ADB вторичен: HTTP уже доступен, но при наличии 5555 подключаем и его.
    unawaited(adb.checkDevice(reg.ip));
    if (!mounted) return;
    if (!reg.isReconnect) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Планшет добавлен: ${reg.name} (${reg.ip})'),
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 5),
      ));
      // Переходим на вкладку Планшеты — там карточки с управлением
      setState(() => _selectedIndex = 0);
    }
    _dashboardKey.currentState?._refresh();
  }

  Future<void> _checkForUpdate({Duration delay = Duration.zero}) async {
    if (_checkingForUpdate || _updateDialogVisible) return;
    if (delay > Duration.zero) await Future.delayed(delay);
    if (!mounted || _checkingForUpdate || _updateDialogVisible) return;
    _checkingForUpdate = true;
    try {
      final info = await AppUpdater.checkForUpdate();
      if (info == null || !mounted) return;
      _showUpdateDialog(info);
    } finally {
      _checkingForUpdate = false;
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    if (_updateDialogVisible || !mounted) return;
    _updateDialogVisible = true;
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: Row(
          children: [
            const Icon(Icons.system_update_rounded,
                color: Colors.blue, size: 22),
            const SizedBox(width: 10),
            Text('Обновление ${info.version}',
                style: const TextStyle(fontSize: 17)),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Текущая версия: $kAppVersion',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              if (info.changelog.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Что нового:',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(info.changelog,
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 12)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Позже', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(c);
              _runUpdate(info);
            },
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Обновить'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    ).whenComplete(() => _updateDialogVisible = false);
  }

  void _runUpdate(UpdateInfo info) {
    double progress = 0;
    String status = '';
    final cancel = CancelToken();
    bool cancelledByUser = false;
    // Прогресс приходит из фоновой загрузки — обновляем именно диалог через его
    // собственный setState (setLocal), иначе полоска «висит» на 0%.
    StateSetter? setDialog;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) {
          setDialog = setLocal;
          return AlertDialog(
            backgroundColor: const Color(0xFF2C2C2E),
            title: Row(
              children: [
                const Expanded(child: Text('Обновление...')),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white54, size: 20),
                  tooltip: 'Отменить',
                  splashRadius: 18,
                  onPressed: () {
                    cancelledByUser = true;
                    cancel.cancel();
                    Navigator.pop(c);
                  },
                ),
              ],
            ),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    // progress < 0 → размер неизвестен, показываем бесконечную полосу
                    value: progress < 0 ? null : progress,
                    backgroundColor: Colors.white12,
                    color: Colors.blue,
                  ),
                  const SizedBox(height: 12),
                  Text(status,
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 12)),
                ],
              ),
            ),
          );
        },
      ),
    );

    // Колбэк прилетает на каждый сетевой чанк (сотни раз в секунду) —
    // перерисовываем диалог не чаще ~10 раз/с. Фазы после загрузки
    // (распаковка/применение, progress ≥ 0.86) показываем всегда.
    var lastDialogUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    AppUpdater.downloadAndApply(info, (p, s) {
      if (!mounted || cancelledByUser) return;
      progress = p;
      status = s;
      if (p < 0.86) {
        final now = DateTime.now();
        if (now.difference(lastDialogUpdate).inMilliseconds < 100) return;
        lastDialogUpdate = now;
      }
      setDialog?.call(() {});
    }, cancel: cancel)
        .then((ok) {
      if (cancelledByUser) return; // диалог уже закрыт крестиком
      if (!ok && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _showUpdateFailedDialog(AppUpdater.lastError);
      }
    });
  }

  /// Автообновление не удалось — даём ссылку на релизы, чтобы скачать вручную.
  void _showUpdateFailedDialog(String? error) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Row(
          children: [
            Icon(Icons.error_outline_rounded,
                color: Colors.redAccent, size: 22),
            SizedBox(width: 10),
            Text('Не удалось обновить', style: TextStyle(fontSize: 17)),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (error != null && error.isNotEmpty) ...[
                Text('Причина: $error',
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 12)),
                const SizedBox(height: 12),
              ],
              const Text('Скачайте свежую версию вручную:',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 6),
              const SelectableText(kReleasesPageUrl,
                  style: TextStyle(color: Colors.blue, fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child:
                const Text('Закрыть', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(c);
              _openUrl(kReleasesPageUrl);
            },
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Открыть GitHub'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  /// Открывает ссылку в браузере по умолчанию (как в проекте принято — через
  /// системную команду, без доп. зависимостей).
  Future<void> _openUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url], runInShell: true);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (e) {
      AppLogger.log('Открыть ссылку: $e');
    }
  }

  Future<void> _cleanupOnStart() async {
    await adb.cleanupOffline();
  }

  @override
  void dispose() {
    _schedulerTimer?.cancel();
    _updateTimer?.cancel();
    _adminModeTimer?.cancel();
    _regSub?.cancel();
    super.dispose();
  }

  void _refreshAdminTimeout() {
    if (!_adminMode) return;
    _adminModeTimer?.cancel();
    _adminModeTimer = Timer(const Duration(minutes: 10), () {
      if (!mounted) return;
      setState(() {
        _adminMode = false;
        if (_selectedIndex > 1) _selectedIndex = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Режим администратора завершён'),
      ));
    });
  }

  Future<void> _showAdminLogin() async {
    final controller = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF242428),
        title: const Text('Вход администратора'),
        content: SizedBox(
          width: 340,
          child: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            onSubmitted: (_) => Navigator.pop(c, controller.text == _adminPin),
            decoration: const InputDecoration(
              labelText: 'PIN-код',
              helperText: 'Технические разделы будут открыты на 10 минут',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text == _adminPin),
            child: const Text('Войти'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted) return;
    if (accepted == true) {
      setState(() => _adminMode = true);
      _refreshAdminTimeout();
    } else if (accepted == false) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Неверный PIN-код'),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  void _leaveAdminMode() {
    _adminModeTimer?.cancel();
    setState(() {
      _adminMode = false;
      if (_selectedIndex > 1) _selectedIndex = 0;
    });
  }

  void _startScheduler() {
    _schedulerTimer =
        Timer.periodic(const Duration(seconds: 30), (timer) async {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('autoOffEnabled') ?? false;
      if (!enabled) return;

      final offTime = prefs.getString('autoOffTime') ?? "22:00";
      final now = DateTime.now();
      final currentTime = DateFormat('HH:mm').format(now);

      if (currentTime == offTime && _lastTriggerMinute != currentTime) {
        _lastTriggerMinute = currentTime;
        AppLogger.log(
            "АВТОМАТИЧЕСКОЕ РАСПИСАНИЕ: Пора выключать экраны ($offTime)");
        final saved = await DeviceStorage.load();
        await adb.bulkSleep(saved.map((d) => d.ip).toList());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final pack = BrandPacks.current.value;
    final accent = Theme.of(context).colorScheme.primary;
    final List<Widget> screens = [
      DashboardScreen(key: _dashboardKey, employeeMode: !_adminMode),
      MediaScreen(employeeMode: !_adminMode),
      BrandPackScreen(onSelect: _selectBrandPack),
      SettingsScreen(key: _settingsKey),
      const LogsScreen(),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF111114),
      body: Row(
        children: [
          Container(
            width: 224,
            padding: const EdgeInsets.fromLTRB(14, 24, 14, 16),
            decoration: BoxDecoration(
              color: const Color(0xFF151518),
              border: Border(
                right: BorderSide(color: Colors.white.withValues(alpha: 0.065)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        pack.mark,
                        style: const TextStyle(
                          color: Color(0xFF101012),
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pack.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: .5)),
                          const SizedBox(height: 2),
                          Text(
                              _adminMode
                                  ? "АДМИНИСТРАТОР · v$kAppVersion"
                                  : "УПРАВЛЕНИЕ ЭКРАНАМИ",
                              style: const TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.white38,
                                  letterSpacing: .7)),
                        ],
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 25),
                _navItem(0, Icons.grid_view_rounded, "Экраны"),
                _navItem(1, Icons.video_library_outlined, "Контент"),
                if (_adminMode) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 18, 12, 7),
                    child: Text('АДМИНИСТРИРОВАНИЕ',
                        style: TextStyle(
                            color: Colors.white24,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2)),
                  ),
                  _navItem(2, Icons.diamond_outlined, "Бренд"),
                  _navItem(
                      3, Icons.tablet_android_rounded, "Планшеты и настройки"),
                  _navItem(
                      4, Icons.monitor_heart_outlined, "Диагностика и логи"),
                ],
                const Spacer(),
                if (_adminMode)
                  Container(
                    margin: const EdgeInsets.fromLTRB(6, 0, 6, 12),
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .035),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                            color: accent, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'Пакет ${pack.version}\nактуален',
                          style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 10.5,
                              height: 1.4),
                        ),
                      ),
                      Icon(Icons.verified_rounded, size: 16, color: accent),
                    ]),
                  ),
                _sideAction(
                  _adminMode
                      ? Icons.lock_open_rounded
                      : Icons.lock_outline_rounded,
                  _adminMode
                      ? 'Выйти из режима администратора'
                      : 'Вход администратора',
                  _adminMode ? _leaveAdminMode : _showAdminLogin,
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Expanded(
                      child: _sideAction(
                        Icons.unfold_less_rounded,
                        'В трей',
                        () {
                          AppLogger.log("Сворачивание в трей");
                          tray.hideToTray();
                        },
                      ),
                    ),
                    if (_adminMode) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: _sideAction(
                            Icons.article_outlined, 'Файл лога', _openLog),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            // Раньше здесь был полноэкранный BackdropFilter (blur 10×10) — он
            // пересчитывался каждый кадр и давал заметные лаги при скролле и
            // анимациях, а визуально поверх градиента почти ничего не давал.
            // Убран. IndexedStack сохраняет состояние вкладок при переключении.
            child: IndexedStack(
              index: _selectedIndex,
              children: screens,
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    bool active = _selectedIndex == index;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: _HoverBuilder(
        builder: (hovered) => InkWell(
          onTap: () {
            setState(() => _selectedIndex = index);
            if (index == 3) {
              unawaited(_settingsKey.currentState?._loadDevices());
            }
            _refreshAdminTimeout();
          },
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: active
                  ? accent.withValues(alpha: 0.14)
                  : hovered
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                AnimatedScale(
                  scale: active ? 1.1 : 1.0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: Icon(icon,
                      color: active ? accent : Colors.white54, size: 19),
                ),
                const SizedBox(width: 12),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 180),
                  style: TextStyle(
                      color: active
                          ? Colors.white
                          : hovered
                              ? Colors.white70
                              : Colors.white60,
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal),
                  child: Text(label),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sideAction(
      IconData icon, String label, FutureOr<void> Function() action) {
    return InkWell(
      onTap: action,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(children: [
          Icon(icon, size: 15, color: Colors.white38),
          const SizedBox(height: 4),
          Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 9.5)),
        ]),
      ),
    );
  }

  Future<void> _selectBrandPack(BrandPack pack) async {
    await BrandPacks.select(pack);
    final devices = await DeviceStorage.load();
    final applied = await Future.wait(
        devices.map((device) => DeviceHttp(device.ip).applyBrandPack(pack)));
    final count = applied.where((ok) => ok).length;
    AppLogger.log(
        'Бренд-пакет ${pack.name}: применён на $count/${devices.length} планшетах');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(devices.isEmpty
          ? 'Пакет ${pack.name} выбран. Добавьте планшеты, чтобы применить его.'
          : 'Пакет ${pack.name} применён: $count из ${devices.length} планшетов.'),
    ));
  }
}

/// Отслеживает наведение мыши и пересобирает потомка с флагом hovered.
/// Для плавных hover-эффектов на десктопе без дублирования MouseRegion.
class _HoverBuilder extends StatefulWidget {
  final Widget Function(bool hovered) builder;
  const _HoverBuilder({required this.builder});
  @override
  State<_HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<_HoverBuilder> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(_hovered),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  final bool employeeMode;
  const DashboardScreen({super.key, this.employeeMode = true});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

/// Переводит технические ошибки в понятные пользователю фразы с подсказкой.
/// Сообщения, уже написанные по-русски (из SyncResult), пропускает как есть.
String humanizeError(String? raw) {
  if (raw == null || raw.trim().isEmpty) return 'Неизвестная ошибка';
  final s = raw.toLowerCase();
  if (s.contains('timeout') ||
      s.contains('timed out') ||
      s.contains('deadline')) {
    return 'Планшет не ответил вовремя — проверьте, что он включён и в сети';
  }
  if (s.contains('certificate') || s.contains('handshake')) {
    return 'Проблема с сертификатом — возможно, антивирус или прокси перехватывает соединение';
  }
  if (s.contains('connection refused') ||
      s.contains('socketexception') ||
      s.contains('failed host lookup') ||
      s.contains('no route') ||
      s.contains('unreachable') ||
      s.contains('connection closed') ||
      s.contains('connection reset')) {
    return 'Нет связи с планшетом — проверьте Wi-Fi и что плеер запущен';
  }
  if (s.contains('no space') || s.contains('enospc')) {
    return 'На планшете закончилось место';
  }
  if (s.contains('adb') &&
      !RegExp(r'[а-яё]', caseSensitive: false).hasMatch(raw)) {
    return 'Связь по USB (ADB) недоступна — работаем по сети';
  }
  // Уже человеческое русское сообщение — оставляем как есть.
  if (RegExp(r'[а-яё]', caseSensitive: false).hasMatch(raw)) return raw;
  return 'Ошибка связи с планшетом';
}

/// Состояние операции на ОДНОМ планшете — показывается инлайн на карточке,
/// вместо модального диалога. Несколько планшетов могут иметь свои операции
/// одновременно, и приложение остаётся отзывчивым.
enum DeviceOpKind { busy, success, error }

class DeviceOp {
  final DeviceOpKind kind;
  final String label; // короткий текст статуса
  final double? progress; // 0..1; null = неопределённый прогресс
  const DeviceOp(this.kind, this.label, {this.progress});

  const DeviceOp.busy(String label, {double? progress})
      : this(DeviceOpKind.busy, label, progress: progress);
  const DeviceOp.success(String label) : this(DeviceOpKind.success, label);
  const DeviceOp.error(String label) : this(DeviceOpKind.error, label);

  bool get isBusy => kind == DeviceOpKind.busy;
}

class _DashboardScreenState extends State<DashboardScreen> {
  final adb = AdbManager();
  List<SavedDevice> saved = [];
  Map<String, DeviceStatus> statuses = {};
  Timer? _screenshotTimer;
  Timer? _statusTimer;
  final Map<String, String> _thumbnails = {};
  bool _isLoading = false;
  bool _isRegistering = false;
  // Идёт МАССОВАЯ операция (Синхронизировать все / Запустить все / Завершить
  // смену). Блокирует только панельные кнопки массовых операций — карточки
  // остаются отзывчивыми.
  bool _busy = false;
  bool _bulkCancel = false;
  bool _reconcilingDesired = false;
  // Текущее положение общего (мастер) ползунка яркости — применяется ко всем
  // онлайн-планшетам сразу. По умолчанию максимум (255).
  int _masterBrightness = 255;

  // Инлайн-состояние операции по каждому планшету (ip → DeviceOp) и набор ip,
  // для которых запрошена отмена.
  final Map<String, DeviceOp> _ops = {};
  final Set<String> _cancel = {};

  /// Выполняет массовую операцию монопольно: на время блокируются панельные
  /// кнопки массовых действий (но не отдельные карточки).
  Future<void> _guard(Future<void> Function() op) async {
    if (_busy) return;
    if (mounted) setState(() => _busy = true);
    try {
      await op();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ставит/снимает инлайн-статус операции на карточке планшета.
  void _setOp(String ip, DeviceOp? op) {
    if (!mounted) return;
    setState(() {
      if (op == null) {
        _ops.remove(ip);
      } else {
        _ops[ip] = op;
      }
    });
  }

  /// Через [after] убирает терминальный статус (успех/ошибка), если его не
  /// сменила новая операция. Сравнение по identity — чтобы не стереть свежий.
  void _clearOpLater(String ip, {Duration after = const Duration(seconds: 5)}) {
    final snapshot = _ops[ip];
    if (snapshot == null) return;
    Future.delayed(after, () {
      if (!mounted) return;
      if (identical(_ops[ip], snapshot)) {
        setState(() => _ops.remove(ip));
      }
    });
  }

  /// Короткое глобальное уведомление (для общих сообщений, не привязанных к
  /// конкретному планшету). Единый спокойный стиль вместо разнобоя SnackBar.
  void _toast(String message, {bool warn = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor:
            warn ? Colors.orange.shade800 : const Color(0xFF333335),
        duration: const Duration(seconds: 3),
      ));
  }

  @override
  void initState() {
    super.initState();
    _cleanupOldThumbs();
    _refresh();
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!_isLoading && !_busy) _refresh();
    });
    _screenshotTimer =
        Timer.periodic(const Duration(minutes: 5), (timer) => _captureAll());
  }

  @override
  void dispose() {
    _screenshotTimer?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _captureAll() async {
    // Параллельно: раньше скриншоты снимались по очереди через ADB screencap,
    // и refresh с несколькими планшетами заметно подвисал.
    await Future.wait(saved
        .where((d) => statuses[d.ip]?.online == true)
        .map((d) => _captureOne(d.ip)));
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _isLoading = true);
    final list = await DeviceStorage.load();
    for (final device in list) {
      DeviceHttp.registerToken(device.ip, device.apiToken);
    }
    AppLogger.log('[UI] Обновление статусов: ${list.length} планшетов');
    // Карточки показываем сразу (со старым/пустым статусом), а статус каждого
    // планшета подставляем по мере готовности — не ждём, пока проверятся все.
    if (mounted) {
      setState(() {
        saved = list;
        // Убираем статусы/превью удалённых планшетов — иначе счётчик
        // «N из M в сети» врёт, а файлы превью копятся.
        final ips = list.map((d) => d.ip).toSet();
        statuses.removeWhere((ip, _) => !ips.contains(ip));
        _thumbnails.removeWhere((ip, path) {
          if (ips.contains(ip)) return false;
          _disposeThumbFile(path);
          return true;
        });
      });
    }
    await adb.checkAll(
      list.map((d) => d.ip).toList(),
      onResult: (status) {
        if (!mounted) return;
        setState(() => statuses[status.ip] = status);
        unawaited(DeviceStorage.updateIdentity(
          status.ip,
          deviceId: status.deviceId,
        ));
        // Снимаем превью сразу, как планшет оказался онлайн.
        if (status.online) _captureOne(status.ip);
      },
    );
    if (mounted) setState(() => _isLoading = false);
    unawaited(_reconcileDesiredState());
  }

  /// Планшет, вернувшийся в сеть, сам догоняет последнюю запрошенную версию.
  /// Legacy-устройства не затрагиваем: автоматический desired-state работает
  /// только для проверяемого deployment protocol v2.
  Future<void> _reconcileDesiredState() async {
    if (_reconcilingDesired || _busy || !mounted) return;
    _reconcilingDesired = true;
    try {
      final devices = await DeviceStorage.load();
      ContentDeployment? available;
      try {
        final mediaDir = await MediaConfig.resolveDir();
        available = await DeploymentBuilder.fromMediaDirectory(mediaDir);
      } catch (e) {
        AppLogger.log('[DESIRED] текущий набор нельзя проверить: $e');
        return;
      }
      for (final device in devices) {
        if (!mounted || _busy) return;
        final desired = device.desiredDeploymentId;
        final status = statuses[device.ip];
        if (desired == null ||
            desired.isEmpty ||
            available.deploymentId != desired ||
            status?.online != true ||
            status?.protocolVersion != kDeploymentProtocolVersion ||
            status?.activeDeploymentId == desired ||
            (_ops[device.ip]?.isBusy ?? false)) {
          continue;
        }
        AppLogger.log('[DESIRED] ${device.ip}: active='
            '${status?.activeDeploymentId} desired=$desired — применяю');
        await _runDeviceSync(device, launch: false);
      }
    } finally {
      _reconcilingDesired = false;
    }
  }

  /// Снимок экрана одного планшета (для мгновенного превью при обнаружении).
  ///
  /// Имя файла с меткой времени: FileImage кэширует картинку по пути, и при
  /// перезаписи того же файла превью на карточке НЕ обновлялось до перезапуска
  /// приложения (и AnimatedSwitcher с ключом-путём не видел смены). Новый путь
  /// на каждый снимок решает обе проблемы; старый файл удаляем.
  Future<void> _captureOne(String ip) async {
    final tempDir = await getTemporaryDirectory();
    final path = p.join(tempDir.path,
        "thumb_${ip.replaceAll('.', '_')}_${DateTime.now().millisecondsSinceEpoch}.png");
    final result = await adb.takeScreenshot(ip, path);
    if (result == null) return;
    final old = _thumbnails[ip];
    if (mounted) setState(() => _thumbnails[ip] = result);
    if (old != null && old != result) _disposeThumbFile(old);
  }

  /// Удаляет старый файл превью и выбрасывает его из кэша декодированных
  /// картинок (иначе растровые копии копятся в памяти).
  void _disposeThumbFile(String path) {
    final f = File(path);
    FileImage(f).evict();
    f.delete().catchError((_) => f);
  }

  /// Чистит осиротевшие thumb_*.png прошлых запусков из temp-папки.
  Future<void> _cleanupOldThumbs() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final live = _thumbnails.values.toSet();
      await for (final e in tempDir.list()) {
        if (e is File &&
            p.basename(e.path).startsWith('thumb_') &&
            e.path.endsWith('.png') &&
            !live.contains(e.path)) {
          await e.delete().catchError((_) => e);
        }
      }
    } catch (_) {}
  }

  Future<void> _registerViaUsb({bool prepareFullWifiControl = false}) async {
    setState(() => _isRegistering = true);
    final usbDevices = await adb.getUsbDevices();
    if (!mounted) {
      return;
    }

    if (usbDevices.isEmpty) {
      setState(() => _isRegistering = false);
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: const Text("Нет USB устройств"),
          content: const Text(
              "Подключите планшет через USB и включите отладку по USB на нём."),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text("OK"))
          ],
        ),
      );
      return;
    }

    int added = 0;
    for (final id in usbDevices) {
      AppLogger.log("Регистрация через USB: $id");
      final registration =
          await adb.registerViaUsb(id, makeDeviceOwner: prepareFullWifiControl);
      final ip = registration.ip;
      if (!mounted) return;
      if (prepareFullWifiControl && !registration.ownerReady) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Планшет $id не подготовлен: ${registration.message}'),
          backgroundColor: Colors.orange.shade800,
        ));
        continue;
      }
      if (ip != null) {
        final nextIndex = (await DeviceStorage.load()).length + 1;
        await DeviceStorage.add(ip, name: "Планшет $nextIndex");
        if (!mounted) return;
        added++;
        final ownerNote = prepareFullWifiControl
            ? registration.adbPersistent
                ? ' Полное управление и резервный ADB готовы.'
                : ' Основное управление по Wi‑Fi готово. ${registration.message}'
            : registration.adbReady
                ? ' ADB по Wi‑Fi подключён.'
                : ' ${registration.message}';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Планшет $ip зарегистрирован и сохранён.$ownerNote"),
          backgroundColor: registration.adbReady
              ? Colors.green.shade700
              : Colors.orange.shade800,
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Не удалось зарегистрировать $id"),
          backgroundColor: Colors.red.shade700,
        ));
      }
    }
    setState(() => _isRegistering = false);
    if (added > 0) await _refresh();
  }

  /// D1: единый мастер добавления планшета (USB / по сети / вручную по IP).
  Future<void> _showAddDeviceWizard() async {
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text("Добавить планшет", style: TextStyle(fontSize: 18)),
        content: SizedBox(
          width: 430,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _addOption(Icons.usb_rounded, Colors.greenAccent, "По USB",
                  "Планшет подключён кабелем, включена отладка по USB", () {
                Navigator.pop(c);
                _registerViaUsb();
              }),
              const SizedBox(height: 10),
              _addOption(
                  Icons.admin_panel_settings_rounded,
                  Colors.lightBlueAccent,
                  "Полное управление по Wi‑Fi",
                  "Чистый планшет по USB: назначит Device Owner, затем включит Wi‑Fi ADB",
                  () {
                Navigator.pop(c);
                _registerViaUsb(prepareFullWifiControl: true);
              }),
              const SizedBox(height: 10),
              _addOption(
                  Icons.wifi_tethering_rounded,
                  Colors.blue,
                  "По сети (спаривание)",
                  "Откроется окно на 60 сек — нажмите «Найти» в Brandmen Ads на планшете",
                  () {
                Navigator.pop(c);
                _startNetworkPairing();
              }),
              const SizedBox(height: 10),
              _addOption(Icons.keyboard_rounded, Colors.white70,
                  "Вручную по IP", "Если знаете IP-адрес планшета в сети", () {
                Navigator.pop(c);
                _addByIp();
              }),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text("Закрыть",
                  style: TextStyle(color: Colors.white54))),
        ],
      ),
    );
  }

  Widget _addOption(IconData icon, Color color, String title, String sub,
      VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.white54)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white24),
          ],
        ),
      ),
    );
  }

  /// Спаривание по сети: открываем окно регистрации и ждём, пока планшет
  /// зарегистрируется (это делает глобальный _onDeviceRegistered).
  Future<void> _startNetworkPairing() async {
    final server = BrandmenServer.instance;

    if (server == null) {
      _toast("Сервер не запущен", warn: true);
      return;
    }
    final until = DateTime.now().add(const Duration(seconds: 60));
    server.startPairing(duration: const Duration(seconds: 60));
    final secs = ValueNotifier<int>(60);
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = until.difference(DateTime.now()).inSeconds;
      secs.value = left < 0 ? 0 : left;
    });
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => ValueListenableBuilder<int>(
        valueListenable: secs,
        builder: (_, left, __) {
          // Авто-закрытие, когда спаривание завершилось (планшет
          // зарегистрировался или истекло время).
          if (!server.pairingActive || left <= 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.canPop(c)) Navigator.pop(c);
            });
          }
          return AlertDialog(
            backgroundColor: const Color(0xFF2C2C2E),
            title: const Text("Спаривание по сети",
                style: TextStyle(fontSize: 17)),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "На планшете откройте Brandmen Ads → «Найти» (или укажите "
                    "IP этого ПК). Как только планшет зарегистрируется, он "
                    "появится в списке.",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  Text("Осталось: $left с",
                      style: const TextStyle(
                          color: Colors.blue,
                          fontSize: 14,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(
                      backgroundColor: Colors.white12, color: Colors.blue),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  server.stopPairing();
                  if (Navigator.canPop(c)) Navigator.pop(c);
                },
                child: const Text("Отмена",
                    style: TextStyle(color: Colors.white54)),
              ),
            ],
          );
        },
      ),
    );
    timer.cancel();
    secs.dispose();
    server.stopPairing();
  }

  /// Добавление планшета по введённому IP.
  Future<void> _addByIp() async {
    final controller = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text("Добавить по IP", style: TextStyle(fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: "192.168.x.x", border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(c, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text("Отмена")),
          TextButton(
              onPressed: () => Navigator.pop(c, controller.text.trim()),
              child: const Text("Добавить")),
        ],
      ),
    );
    if (ip == null || ip.isEmpty) return;
    if (!RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip)) {
      _toast("Неверный IP-адрес", warn: true);
      return;
    }
    await DeviceStorage.add(ip, name: "Планшет ${saved.length + 1}");
    await _refresh();
  }

  Future<void> _setPlayback(SavedDevice dev, bool enabled) async {
    final ip = dev.ip;
    if (_ops[ip]?.isBusy ?? false) return;
    _setOp(
        ip, DeviceOp.busy(enabled ? "Включаю рекламу…" : "Выключаю рекламу…"));
    final accepted =
        enabled ? await adb.enablePlayback(ip) : await adb.disablePlayback(ip);
    if (enabled) {
      final playing = accepted && await adb.verifyPlaying(ip);
      _setOp(
          ip,
          playing
              ? const DeviceOp.success("Реклама включена ▶")
              : const DeviceOp.error(
                  "Команда принята, но ролик не запустился"));
    } else {
      _setOp(
          ip,
          accepted
              ? const DeviceOp.success("Реклама выключена")
              : const DeviceOp.error(
                  "Старый плеер: экран погашен без подтверждения"));
    }
    _clearOpLater(ip, after: const Duration(seconds: 6));
    await _refresh();
  }

  Future<void> _setPlaybackAll(bool enabled) async {
    final online = saved.where((d) => statuses[d.ip]?.online == true).toList();
    if (online.isEmpty) {
      _toast("Нет онлайн-планшетов", warn: true);
      return;
    }
    for (final dev in online) {
      _setOp(dev.ip,
          DeviceOp.busy(enabled ? "Включаю рекламу…" : "Выключаю рекламу…"));
    }
    await Future.wait(online.map((dev) async {
      final accepted = enabled
          ? await adb.enablePlayback(dev.ip)
          : await adb.disablePlayback(dev.ip);
      final ok =
          enabled ? accepted && await adb.verifyPlaying(dev.ip) : accepted;
      _setOp(
          dev.ip,
          ok
              ? DeviceOp.success(
                  enabled ? "Реклама включена ▶" : "Реклама выключена")
              : DeviceOp.error(
                  enabled ? "Не запустился" : "Не подтвердил выключение"));
      _clearOpLater(dev.ip, after: const Duration(seconds: 6));
    }));
    await _refresh();
  }

  Future<void> _showDeviceControls(SavedDevice dev) async {
    // Громкость/яркость/максимум приходят одним /api/control/status — раньше
    // диалог открывался тремя одинаковыми запросами подряд. ADB-фолбэк
    // остаётся на случай, когда HTTP недоступен.
    final st = await DeviceHttp(dev.ip).controlStatus();
    final vol = st != null ? st['volume']! : await adb.getVolume(dev.ip);
    final bright =
        st != null ? st['brightness']! : await adb.getBrightness(dev.ip);
    final volMax = st?['volumeMax'] ?? 15;
    // Техданные (версия/owner/онлайн) тянем только в режиме разработчика —
    // персоналу лишний запрос не нужен.
    final health = AppSettings.developerMode.value
        ? await DeviceHttp(dev.ip).health()
        : null;
    if (!mounted) return;

    int currentVol = vol;
    int currentBright = bright;
    final maxVol = volMax.clamp(1, 100);

    await showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: Text(dev.name, style: const TextStyle(fontSize: 18)),
          content: SizedBox(
            width: 360,
            child: SliderTheme(
              data: SliderTheme.of(c).copyWith(
                activeTrackColor: Colors.blue,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.blue.withValues(alpha: 0.2),
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                valueIndicatorColor: Colors.blue,
                valueIndicatorTextStyle: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.volume_up_rounded,
                          color: Colors.white70),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          value:
                              currentVol.toDouble().clamp(0, maxVol.toDouble()),
                          min: 0,
                          max: maxVol.toDouble(),
                          divisions: maxVol,
                          label: "$currentVol",
                          onChanged: (v) =>
                              setLocal(() => currentVol = v.round()),
                          onChangeEnd: (v) async {
                            await adb.setVolume(dev.ip, v.round());
                          },
                        ),
                      ),
                      SizedBox(
                          width: 44,
                          child: Text("$currentVol/$maxVol",
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                              textAlign: TextAlign.right)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Icon(Icons.brightness_6_rounded,
                          color: Colors.white70),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          value: currentBright.toDouble(),
                          min: 1,
                          max: 255,
                          divisions: 50,
                          label: "${(currentBright * 100 ~/ 255)}%",
                          onChanged: (v) =>
                              setLocal(() => currentBright = v.round()),
                          onChangeEnd: (v) async {
                            await adb.setBrightness(dev.ip, v.round());
                          },
                        ),
                      ),
                      SizedBox(
                          width: 44,
                          child: Text("${currentBright * 100 ~/ 255}%",
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                              textAlign: TextAlign.right)),
                    ],
                  ),
                  if (AppSettings.developerMode.value)
                    ..._devSection(dev, health, c),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text("Закрыть")),
          ],
        ),
      ),
    );
  }

  /// Техническая секция диалога управления — видна только в режиме разработчика.
  /// Персоналу (режим выключен) показываются лишь громкость и яркость.
  List<Widget> _devSection(
      SavedDevice dev, Map<String, dynamic>? health, BuildContext dialogCtx) {
    String yn(bool? b) => b == null ? "—" : (b ? "да" : "нет");
    final ver = (health?['version'] ?? '') as String;
    final owner = health?['deviceOwner'] as bool?;
    final online = health?['online'] as bool?;
    final batt = health?['battery'] as int?;
    final info = [
      if (ver.isNotEmpty) "версия $ver",
      "owner: ${yn(owner)}",
      "онлайн: ${yn(online)}",
      if (batt != null && batt >= 0) "батарея $batt%",
    ].join(" · ");
    return [
      const SizedBox(height: 20),
      const Divider(color: Colors.white12, height: 1),
      const SizedBox(height: 12),
      const Row(children: [
        Icon(Icons.build_rounded, size: 15, color: Colors.orangeAccent),
        SizedBox(width: 6),
        Text("Режим разработчика",
            style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 12,
                fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: Text(info,
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.redAccent,
            side: const BorderSide(color: Colors.redAccent),
          ),
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: const Text("Перезагрузить планшет"),
          onPressed: () => _confirmAndReboot(dev, dialogCtx),
        ),
      ),
      if (owner == false) ...[
        const SizedBox(height: 6),
        const Text("Ребут работает только в режиме Device Owner",
            style: TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    ];
  }

  Future<void> _confirmAndReboot(
      SavedDevice dev, BuildContext dialogCtx) async {
    final ok = await showDialog<bool>(
      context: dialogCtx,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text("Перезагрузить планшет?",
            style: TextStyle(fontSize: 16)),
        content: Text("«${dev.name}» перезагрузится. Займёт ~1 минуту.",
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text("Отмена")),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text("Перезагрузить",
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return;
    final done = await DeviceHttp(dev.ip).reboot();
    if (!mounted) return;
    _toast(done ? "Планшет перезагружается" : "Не удалось (нужен Device Owner)",
        warn: !done);
  }

  Future<void> _syncOnly(SavedDevice dev) => _runDeviceSync(dev, launch: false);

  /// Синхронизация (и опц. запуск) одного планшета — БЕЗ модалки: весь прогресс
  /// и итог показываются инлайн на карточке (`_ops[ip]`). Отмена — через
  /// крестик на карточке (`_cancel`). Можно запускать параллельно для разных
  /// планшетов; повторный запуск того же — игнорируется.
  Future<void> _runDeviceSync(SavedDevice dev, {required bool launch}) async {
    final ip = dev.ip;
    if (_ops[ip]?.isBusy ?? false) return;
    _cancel.remove(ip);
    bool cancelled() => _cancel.contains(ip);
    AppLogger.log(
        '[UI] Нажато: ${launch ? "Синхронизировать и играть" : "Синхронизировать"} '
        '— ${dev.name} ($ip)');

    _setOp(ip, const DeviceOp.busy("Подключение…"));
    final mediaDir = await MediaConfig.resolveDir();
    final norm =
        await Transcoder.normalizeDir(mediaDir, onProgress: (file, i, total) {
      _setOp(
          ip,
          DeviceOp.busy("Конвертация $i/$total",
              progress: total > 0 ? i / total : null));
    });
    if (cancelled()) {
      _setOp(ip, null);
      return;
    }
    // Нельзя отправлять смешанный набор: если хотя бы один ролик не приведён
    // к единому профилю, оставляем на планшете предыдущий рабочий плейлист.
    if (norm.ffmpegMissing || norm.failed.isNotEmpty) {
      _setOp(
          ip,
          DeviceOp.error(norm.ffmpegMissing
              ? 'Нужен ffmpeg для подготовки видео'
              : 'Не удалось подготовить: ${norm.failed.join(', ')}'));
      _clearOpLater(ip, after: const Duration(seconds: 10));
      if (norm.ffmpegMissing) await _showFfmpegMissingDialog();
      return;
    }

    ContentDeployment deployment;
    try {
      _setOp(ip, const DeviceOp.busy("Проверяю набор роликов…"));
      deployment = await DeploymentBuilder.fromMediaDirectory(mediaDir);
      await DeviceStorage.setDesired([ip], deployment.deploymentId);
    } catch (e) {
      _setOp(ip, DeviceOp.error(humanizeError('$e')));
      _clearOpLater(ip, after: const Duration(seconds: 10));
      return;
    }

    final result = await adb.syncDeviceDirect(
      ip,
      mediaDir,
      tryHttpFirst: statuses[ip]?.httpAvailable ?? true,
      isCancelled: cancelled,
      forceUpload: norm.converted.isNotEmpty,
      deployment: deployment,
      onProgress: (done, total, file) {
        if (file.isNotEmpty) {
          _setOp(
              ip,
              DeviceOp.busy("$done/$total",
                  progress: total > 0 ? done / total : null));
        }
      },
    );
    if (cancelled()) {
      _setOp(ip, null);
      return;
    }

    if (!result.success) {
      _setOp(ip, DeviceOp.error(humanizeError(result.error)));
      _clearOpLater(ip, after: const Duration(seconds: 8));
      if (norm.ffmpegMissing) await _showFfmpegMissingDialog();
      return;
    }

    // Синхронизация не меняет операторское состояние «реклама включена».
    // Новый Android сам перечитывает manifest и продолжает играть только если
    // до синка был включён. Явный launch — отдельная команда пользователя.
    final shouldLaunch = launch && (statuses[ip]?.online ?? false);
    if (shouldLaunch) {
      _setOp(ip, const DeviceOp.busy("Включаю рекламу…"));
      await adb.enablePlayback(ip);
      _setOp(ip, const DeviceOp.busy("Проверяю воспроизведение…"));
      final isV2 = result.transport == 'Deployment v2';
      final playing = isV2
          ? await adb.verifyDeploymentPlaying(
              ip,
              deploymentId: deployment.deploymentId,
              playlistHash: deployment.playlistHash,
            )
          : await adb.verifyPlaying(ip);
      if (!playing) {
        final rolledBack =
            isV2 ? await DeviceHttp(ip).rollbackDeployment() : false;
        if (rolledBack) await adb.enablePlayback(ip);
        _setOp(
            ip,
            DeviceOp.error(rolledBack
                ? "Новая версия не запустилась — вернул предыдущую"
                : "Плейлист передан, но не запустился"));
        _clearOpLater(ip, after: const Duration(seconds: 10));
        return;
      }
    }

    final base = result.pushed.isEmpty
        ? "Актуально"
        : "Загружено ${result.pushed.length}";
    _setOp(ip, DeviceOp.success(shouldLaunch ? "$base ▶" : base));
    _clearOpLater(ip);
    if (shouldLaunch) _captureOne(ip);
    if (norm.ffmpegMissing) await _showFfmpegMissingDialog();
  }

  /// Синхронизация всех онлайн-устройств. После передачи новый плейлист
  /// автоматически применяется, иначе плеер продолжает показывать старый.
  Future<void> _syncOnlyAll() => _syncAll(launch: false);

  /// Прогон по всем онлайн-устройствам последовательно с прогрессом и отменой.
  /// [sync] — сверять/докачивать файлы (иначе только запуск);
  /// [launch] — после этого перезапустить плеер;
  /// [mute] — сразу после запуска поставить громкость 0.
  Future<void> _syncAll(
      {required bool launch, bool mute = false, bool sync = true}) async {
    final online = saved.where((d) => statuses[d.ip]?.online == true).toList();
    if (online.isEmpty) {
      _toast("Нет онлайн-устройств", warn: true);
      return;
    }
    AppLogger.log('[UI] Нажато: массовое действие '
        '(${sync ? "синк" : "без синка"}${launch ? "+играть" : ""}${mute ? "+без звука" : ""}) '
        '— онлайн ${online.length} из ${saved.length}');
    final mediaDir = await MediaConfig.resolveDir();
    if (!mounted) return;

    _bulkCancel = false;
    // Все планшеты сразу помечаем «в очереди» — видно, что процесс пошёл.
    for (final dev in online) {
      _setOp(dev.ip, const DeviceOp.busy("В очереди…"));
    }

    // Конвертация не-mp4 → mp4 один раз для общей медиа-папки (только при синке).
    final norm = sync
        ? await Transcoder.normalizeDir(mediaDir, onProgress: (file, i, total) {
            for (final dev in online) {
              _setOp(
                  dev.ip,
                  DeviceOp.busy("Конвертация $i/$total",
                      progress: total > 0 ? i / total : null));
            }
          })
        : null;

    // Общая папка должна быть либо полностью подготовлена, либо не отправлена
    // никому: иначе часть планшетов получила бы новый набор, а часть — старый.
    if (sync && (norm?.ffmpegMissing == true || norm!.failed.isNotEmpty)) {
      final normalization = norm;
      final reason = normalization!.ffmpegMissing
          ? 'Нужен ffmpeg для подготовки видео'
          : 'Не удалось подготовить: ${normalization.failed.join(', ')}';
      for (final dev in online) {
        _setOp(dev.ip, DeviceOp.error(reason));
        _clearOpLater(dev.ip, after: const Duration(seconds: 10));
      }
      if (normalization.ffmpegMissing) await _showFfmpegMissingDialog();
      return;
    }

    ContentDeployment? deployment;
    if (sync) {
      try {
        for (final dev in online) {
          _setOp(dev.ip, const DeviceOp.busy("Проверяю набор роликов…"));
        }
        deployment = await DeploymentBuilder.fromMediaDirectory(mediaDir);
        await DeviceStorage.setDesired(
          saved.map((device) => device.ip),
          deployment.deploymentId,
        );
      } catch (e) {
        final reason = humanizeError('$e');
        for (final dev in online) {
          _setOp(dev.ip, DeviceOp.error(reason));
          _clearOpLater(dev.ip, after: const Duration(seconds: 10));
        }
        return;
      }
    }

    int failed = 0;
    // Фаза 1: файлы — последовательно (WiFi-канал общий, параллельная заливка
    // не ускоряет). Планшеты, которым нужен запуск, копим на фазу 2.
    final toLaunch = <(SavedDevice, SyncResult)>[];
    for (final dev in online) {
      if (!mounted) return;
      final ip = dev.ip;
      if (_bulkCancel) {
        _setOp(ip, null);
        continue;
      }
      final deviceOnline = statuses[ip]?.online ?? false;

      SyncResult result;
      if (sync) {
        _setOp(ip, const DeviceOp.busy("Подключение…"));
        result = await adb.syncDeviceDirect(
          ip,
          mediaDir,
          tryHttpFirst: statuses[ip]?.httpAvailable ?? true,
          isCancelled: () => _bulkCancel,
          forceUpload: norm?.converted.isNotEmpty ?? false,
          deployment: deployment,
          onProgress: (done, total, file) {
            if (file.isEmpty) return;
            _setOp(
                ip,
                DeviceOp.busy("$done/$total",
                    progress: total > 0 ? done / total : null));
          },
        );
      } else {
        result =
            const SyncResult(success: true, pushed: [], transport: 'launch');
      }

      // Отмена во время синка этого устройства — снимаем статус и выходим.
      if (_bulkCancel && !result.success) {
        _setOp(ip, null);
        continue;
      }

      if (!result.success) {
        _setOp(ip, DeviceOp.error(humanizeError(result.error)));
        _clearOpLater(ip, after: const Duration(seconds: 8));
        continue;
      }

      if (launch && deviceOnline) {
        _setOp(ip, const DeviceOp.busy("Ожидает включения…"));
        toLaunch.add((dev, result));
      } else {
        final base = !sync
            ? "Запущено"
            : (result.pushed.isEmpty
                ? "Актуально"
                : "Готово: ${result.pushed.length}");
        _setOp(ip, DeviceOp.success(base));
        _captureOne(ip);
        _clearOpLater(ip, after: const Duration(seconds: 8));
      }
    }

    // Фаза 2: запуск и проверка «реально играет» — батчами по 3 параллельно.
    // Раньше шло строго по одному, а verifyPlaying ждёт до 30с на планшет:
    // «Запустить все» на 6 планшетах растягивалось на минуты.
    const launchBatch = 3;
    for (var i = 0; i < toLaunch.length; i += launchBatch) {
      if (!mounted) return;
      final batch = toLaunch.skip(i).take(launchBatch);
      await Future.wait(batch.map((entry) async {
        final (dev, result) = entry;
        final ip = dev.ip;
        if (_bulkCancel) {
          _setOp(ip, null);
          return;
        }
        _setOp(
            ip,
            DeviceOp.busy(mute
                ? "Запуск без звука…"
                : (launch ? "Запуск…" : "Применяю плейлист…")));
        await adb.enablePlayback(ip);
        if (mute) await adb.setVolume(ip, 0);
        _setOp(ip, const DeviceOp.busy("Проверка запуска…"));
        final isV2 = result.transport == 'Deployment v2' && deployment != null;
        final launchOk = isV2
            ? await adb.verifyDeploymentPlaying(
                ip,
                deploymentId: deployment.deploymentId,
                playlistHash: deployment.playlistHash,
              )
            : await adb.verifyPlaying(ip);
        if (!launchOk) {
          failed++;
          AppLogger.log('Запуск: плеер не подтвердил запуск на ${dev.name}');
          final rolledBack =
              isV2 ? await DeviceHttp(ip).rollbackDeployment() : false;
          if (rolledBack) await adb.enablePlayback(ip);
          _setOp(
              ip,
              DeviceOp.error(rolledBack
                  ? "Ошибка — восстановлена предыдущая версия"
                  : "Не запустился"));
        } else {
          final base = !sync
              ? "Запущено"
              : (result.pushed.isEmpty
                  ? "Актуально"
                  : "Готово: ${result.pushed.length}");
          _setOp(ip, DeviceOp.success("$base ▶"));
          _captureOne(ip);
        }
        _clearOpLater(ip, after: const Duration(seconds: 8));
      }));
    }

    if (failed > 0) {
      AppLogger.log('Запуск: не подтвердился на $failed устройстве(ах)');
    }
    if (norm?.ffmpegMissing ?? false) await _showFfmpegMissingDialog();
  }

  Future<void> _showFfmpegMissingDialog() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text("Нужен ffmpeg"),
        content: const Text(
          "Каждый ролик, включая .mp4, перед отправкой приводится к единому "
          "профилю для планшетов. Для этого нужен ffmpeg:\n\n"
          "• macOS:  brew install ffmpeg\n"
          "• Windows: скачайте с ffmpeg.org и добавьте в PATH\n\n"
          "После установки повторите синхронизацию.",
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text("Понятно")),
        ],
      ),
    );
  }

  /// Применяет яркость ко всем онлайн-планшетам сразу (общий ползунок).
  Future<void> _setBrightnessAll(int level) async {
    final online = saved.where((d) => statuses[d.ip]?.online == true).toList();
    if (online.isEmpty) {
      _toast("Нет онлайн-устройств", warn: true);
      return;
    }
    AppLogger.log('[UI] Общая яркость → ${level * 100 ~/ 255}% '
        'на ${online.length} планшетах');
    await Future.wait(online.map((d) => adb.setBrightness(d.ip, level)));
  }

  void _endShift() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              backgroundColor: const Color(0xFF2C2C2E),
              title: const Text("Завершить смену?"),
              content: const Text("Все экраны планшетов будут выключены."),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text("Отмена")),
                TextButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text("Выключить всё",
                        style: TextStyle(color: Colors.redAccent))),
              ],
            ));

    if (confirmed == true) {
      AppLogger.log("МАССОВОЕ ВЫКЛЮЧЕНИЕ: Завершение смены");
      await adb.bulkDisablePlayback(saved.map((d) => d.ip));
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final onlineCount = statuses.values.where((s) => s.online).length;
    final readyForWifiControl =
        statuses.values.where((s) => s.fullWifiControlReady).length;
    final accent = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 32, 36, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Экраны",
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.6)),
                  const SizedBox(height: 4),
                  Text(
                      widget.employeeMode
                          ? "$onlineCount из ${saved.length} доступны для управления"
                          : "$onlineCount из ${saved.length} в сети · "
                              "$readyForWifiControl готовы к полному управлению",
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (!widget.employeeMode)
                    OutlinedButton.icon(
                      onPressed: (_isRegistering || _busy)
                          ? null
                          : _showAddDeviceWizard,
                      icon: _isRegistering
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  color: Colors.greenAccent, strokeWidth: 2))
                          : const Icon(Icons.add_rounded),
                      label: const Text("Добавить планшет"),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.greenAccent,
                        side: const BorderSide(color: Colors.greenAccent),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: (saved.isEmpty || _busy)
                        ? null
                        : () => _guard(_syncOnlyAll),
                    icon: const Icon(Icons.sync_rounded),
                    label: const Text("Отправить контент"),
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: const Color(0xFF101012),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 15),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: (saved.isEmpty || _busy)
                        ? null
                        : () => _guard(() => _setPlaybackAll(true)),
                    icon: const Icon(Icons.play_circle_fill_rounded),
                    label: const Text("Начать смену"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  if (!widget.employeeMode)
                    OutlinedButton.icon(
                      onPressed: (saved.isEmpty || _busy)
                          ? null
                          : () => _guard(() => _setPlaybackAll(false)),
                      icon: const Icon(Icons.power_settings_new_rounded),
                      label: const Text("Выключить рекламу"),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  // Общий ползунок яркости — применяется ко всем онлайн сразу.
                  if (!widget.employeeMode)
                    Container(
                      width: 240,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0x80FFC107)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.brightness_6_rounded,
                              color: Colors.amber, size: 20),
                          Expanded(
                            child: Slider(
                              value: _masterBrightness.toDouble(),
                              min: 1,
                              max: 255,
                              divisions: 50,
                              activeColor: Colors.amber,
                              label: "${_masterBrightness * 100 ~/ 255}%",
                              onChanged: saved.isEmpty
                                  ? null
                                  : (v) => setState(
                                      () => _masterBrightness = v.round()),
                              onChangeEnd: (v) => _setBrightnessAll(v.round()),
                            ),
                          ),
                          SizedBox(
                              width: 38,
                              child: Text("${_masterBrightness * 100 ~/ 255}%",
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 12),
                                  textAlign: TextAlign.right)),
                        ],
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: (saved.isEmpty || _busy) ? null : _endShift,
                    icon: const Icon(Icons.power_settings_new_rounded),
                    label: const Text("Завершить смену"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  if (_busy)
                    OutlinedButton.icon(
                      onPressed: _bulkCancel
                          ? null
                          : () => setState(() => _bulkCancel = true),
                      icon: const Icon(Icons.stop_rounded),
                      label: Text(_bulkCancel ? "Останавливаю…" : "Остановить"),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orangeAccent,
                        side: const BorderSide(color: Colors.orangeAccent),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ElevatedButton.icon(
                    onPressed: (_isLoading || _busy) ? null : _refresh,
                    icon: _isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.refresh_rounded),
                    label: const Text("Проверить состояние"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: .08),
                      foregroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              )
            ],
          ),
          const SizedBox(height: 18),
          _overallStatusCard(),
          const SizedBox(height: 20),
          Expanded(
            child: saved.isEmpty
                ? _emptyState()
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final cols =
                          (constraints.maxWidth / 280).floor().clamp(1, 6);
                      return GridView.builder(
                        physics: const BouncingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics()),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          crossAxisSpacing: 20,
                          mainAxisSpacing: 20,
                          childAspectRatio: 1.05,
                        ),
                        itemCount: saved.length,
                        itemBuilder: (context, index) =>
                            _deviceCard(saved[index]),
                      );
                    },
                  ),
          )
        ],
      ),
    );
  }

  Widget _overallStatusCard() {
    final online = statuses.values.where((s) => s.online).length;
    final playing = statuses.values
        .where((s) =>
            s.online && s.playbackEnabled != false && s.playerPlaying == true)
        .length;
    final intentionallyOff = statuses.values
        .where((s) => s.online && s.playbackEnabled == false)
        .length;
    final hasProblems = saved.isNotEmpty &&
        (online < saved.length || playing + intentionallyOff < online);
    final shiftOff =
        saved.isNotEmpty && intentionallyOff == online && online > 0;
    final color = hasProblems
        ? Colors.orangeAccent
        : shiftOff
            ? Colors.blueAccent
            : Colors.greenAccent;
    final title = saved.isEmpty
        ? 'Добавьте первый экран'
        : hasProblems
            ? 'Требуется внимание'
            : shiftOff
                ? 'Смена не запущена'
                : 'Все экраны работают';
    final subtitle = saved.isEmpty
        ? 'Подключение планшетов доступно администратору'
        : hasProblems
            ? '${saved.length - online} не в сети · ${online - playing - intentionallyOff} не начали показ'
            : shiftOff
                ? '$online экранов готовы к началу показа'
                : '$playing экранов показывают рекламу';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 17),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Row(children: [
        Icon(
            hasProblems
                ? Icons.warning_amber_rounded
                : Icons.check_circle_rounded,
            color: color,
            size: 28),
        const SizedBox(width: 14),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ])),
      ]),
    );
  }

  Widget _emptyState() {
    final accent = Theme.of(context).colorScheme.primary;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.tablet_android_rounded,
              size: 80, color: Colors.white.withValues(alpha: 0.1)),
          const SizedBox(height: 20),
          const Text("Нет зарегистрированных планшетов",
              style: TextStyle(color: Colors.white54, fontSize: 18)),
          const SizedBox(height: 8),
          const Text("Добавьте первый планшет — по USB, по сети или по IP",
              style: TextStyle(color: Colors.white24, fontSize: 13)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _isRegistering ? null : _showAddDeviceWizard,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text("Добавить планшет"),
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: const Color(0xFF101012),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _deviceCard(SavedDevice dev) {
    final status = statuses[dev.ip];
    final isOnline = status?.online ?? false;
    // Управление (питание/громкость/яркость) работает и по HTTP, и по ADB,
    // поэтому достаточно, чтобы устройство было онлайн любым способом.
    final canControl = isOnline;
    final bat = int.tryParse(status?.battery ?? "0") ?? 0;
    // Кнопки синка/запуска этой карточки: онлайн, нет массовой операции и нет
    // активной операции на самом этом планшете.
    final opBusy = _ops[dev.ip]?.isBusy ?? false;
    final canAct = isOnline && !_busy && !opBusy;

    return _HoverBuilder(
        builder: (hovered) => AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              transform: hovered
                  ? Matrix4.translationValues(0, -3, 0)
                  : Matrix4.identity(),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: hovered ? 0.07 : 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: isOnline
                        ? Colors.green.withValues(alpha: hovered ? 0.4 : 0.2)
                        : Colors.white.withValues(alpha: 0.05)),
                boxShadow: hovered
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        )
                      ]
                    : null,
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: isOnline
                                  ? Colors.greenAccent
                                  : Colors.white24,
                              shape: BoxShape.circle,
                              boxShadow: isOnline
                                  ? [
                                      BoxShadow(
                                        color: Colors.greenAccent
                                            .withValues(alpha: 0.6),
                                        blurRadius: 6,
                                      )
                                    ]
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                              isOnline
                                  ? (widget.employeeMode
                                      ? "На связи"
                                      : status?.transport ?? "Online")
                                  : (widget.employeeMode
                                      ? "Нет сети"
                                      : "Offline"),
                              style: TextStyle(
                                  fontSize: 11,
                                  color: isOnline
                                      ? Colors.greenAccent
                                      : Colors.white38)),
                          if (!widget.employeeMode)
                            _autoUpdateBadge(dev, status),
                          if (!widget.employeeMode) _accessBadge(dev, status),
                        ],
                      ),
                      if (isOnline && (!widget.employeeMode || bat < 20))
                        Row(
                          children: [
                            Icon(
                                bat < 20
                                    ? Icons.battery_alert_rounded
                                    : Icons.battery_charging_full_rounded,
                                size: 14,
                                color: bat < 20
                                    ? Colors.redAccent
                                    : Colors.white24),
                            const SizedBox(width: 4),
                            Text("${status?.battery ?? "??"}%",
                                style: TextStyle(
                                    fontSize: 12,
                                    color: bat < 20
                                        ? Colors.redAccent
                                        : Colors.white24,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Превью проявляется плавно при обновлении скриншота.
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 350),
                              switchInCurve: Curves.easeOut,
                              child: _thumbnails.containsKey(dev.ip)
                                  ? Image.file(File(_thumbnails[dev.ip]!),
                                      fit: BoxFit.cover,
                                      gaplessPlayback: true,
                                      // Скриншот планшета ~1920×1200, а превью ~250px:
                                      // без cacheWidth каждый держал бы ~9 МБ в памяти
                                      // и тормозил декодированием полного размера.
                                      cacheWidth: 560,
                                      key: ValueKey(_thumbnails[dev.ip]))
                                  : Container(
                                      key: const ValueKey('placeholder'),
                                      color: Colors.black26,
                                      child: Icon(
                                          isOnline
                                              ? Icons.videocam_off_rounded
                                              : Icons.wifi_off_rounded,
                                          color: Colors.white10)),
                            ),
                            // Инлайн-статус операции (синк/запуск/итог) поверх превью.
                            _opOverlay(dev),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(dev.name,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                  if (!widget.employeeMode)
                    Text(dev.ip,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white38)),
                  if (isOnline && !widget.employeeMode) ...[
                    const SizedBox(height: 5),
                    InkWell(
                      onTap: () => _showDeviceOwnerHelp(dev),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: (status?.fullWifiControlReady == true
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent)
                              .withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            status?.fullWifiControlReady == true
                                ? Icons.verified_user_rounded
                                : Icons.admin_panel_settings_outlined,
                            size: 12,
                            color: status?.fullWifiControlReady == true
                                ? Colors.greenAccent
                                : Colors.orangeAccent,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              status?.fullWifiControlReady == true
                                  ? 'Полное Wi‑Fi управление'
                                  : status?.wifiControlHint ??
                                      'Проверяю готовность',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: status?.fullWifiControlReady == true
                                    ? Colors.greenAccent
                                    : Colors.orangeAccent,
                              ),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ],
                  if (status?.playerVersion != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                            status?.playbackEnabled == false
                                ? Icons.power_settings_new_rounded
                                : status?.playerPlaying == true
                                    ? Icons.play_circle_outline_rounded
                                    : Icons.warning_amber_rounded,
                            size: 12,
                            color: status?.playbackEnabled == false
                                ? Colors.white38
                                : status?.playerPlaying == true
                                    ? Colors.greenAccent
                                    : Colors.redAccent),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            widget.employeeMode
                                ? (status?.playbackEnabled == false
                                    ? "Экран выключен"
                                    : status?.playerPlaying == true
                                        ? "Показ идёт"
                                        : "Показ не запустился")
                                : "${status?.playbackEnabled == false ? "Реклама выключена" : status?.playerPlaying == true ? "Реклама играет" : "Должен играть · ошибка"}"
                                    " · v${status?.playerVersion}"
                                    "${status?.freeMb != null ? " · ${status!.freeMb} МБ своб." : ""}",
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 10, color: Colors.white38),
                          ),
                        ),
                      ],
                    ),
                    if ((status?.activeDeploymentId ?? '').isNotEmpty)
                      Text(
                        dev.desiredDeploymentId != null &&
                                dev.desiredDeploymentId !=
                                    status?.activeDeploymentId
                            ? "Контент ${status!.activeDeploymentId!.substring(0, 8)}"
                                " → ожидает ${dev.desiredDeploymentId!.substring(0, 8)}"
                            : "Контент актуален · "
                                "${status!.activeDeploymentId!.substring(0, 8)}",
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9,
                          color: dev.desiredDeploymentId != null &&
                                  dev.desiredDeploymentId !=
                                      status.activeDeploymentId
                              ? Colors.orangeAccent
                              : Colors.greenAccent.withValues(alpha: .8),
                        ),
                      ),
                  ] else if (!isOnline) ...[
                    const SizedBox(height: 4),
                    Text(
                      "Не в сети",
                      style: TextStyle(
                          fontSize: 10, color: Colors.redAccent.shade100),
                    ),
                    if (status?.lastError != null)
                      Text(
                        humanizeError(status?.lastError),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(fontSize: 9, color: Colors.white30),
                      ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _smallAppleBtn(Icons.play_arrow_rounded,
                          canControl ? () => _setPlayback(dev, true) : null,
                          tooltip: "Начать показ", color: Colors.greenAccent),
                      const SizedBox(width: 8),
                      _smallAppleBtn(Icons.sync_rounded,
                          canAct ? () => _syncOnly(dev) : null,
                          tooltip: "Отправить контент",
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      _smallAppleBtn(Icons.power_settings_new_rounded,
                          canControl ? () => _setPlayback(dev, false) : null,
                          tooltip: "Остановить показ", color: Colors.redAccent),
                      const SizedBox(width: 8),
                      _smallAppleBtn(Icons.tune_rounded,
                          canControl ? () => _showDeviceControls(dev) : null,
                          tooltip: "Громкость и яркость"),
                    ],
                  )
                ],
              ),
            ));
  }

  /// Инлайн-оверлей операции поверх превью карточки: прогресс синка/запуска,
  /// либо итог (успех/ошибка), который сам исчезает через несколько секунд.
  /// Плавно появляется/прячется через AnimatedSwitcher.
  Widget _opOverlay(SavedDevice dev) {
    final op = _ops[dev.ip];
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: op == null
          ? const SizedBox.shrink(key: ValueKey('noop'))
          : Container(
              // Ключ по фазе (не по тексту) — иначе AnimatedSwitcher
              // перезапускал бы анимацию на каждом тике прогресса.
              key: ValueKey(op.kind),
              color: Colors.black.withValues(alpha: 0.55),
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (op.isBusy)
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          value: op.progress,
                          color: Colors.white),
                    )
                  else
                    Icon(
                        op.kind == DeviceOpKind.success
                            ? Icons.check_circle_rounded
                            : Icons.error_rounded,
                        size: 28,
                        color: op.kind == DeviceOpKind.success
                            ? Colors.greenAccent
                            : Colors.redAccent),
                  const SizedBox(height: 8),
                  Text(op.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.white)),
                  // Отмена доступна для одиночной операции (в массовой — кнопка
                  // «Остановить» на панели).
                  if (op.isBusy && !_busy) ...[
                    const SizedBox(height: 6),
                    InkWell(
                      onTap: () => _cancelDeviceOp(dev.ip),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        child: Text("Отмена",
                            style: TextStyle(
                                fontSize: 11, color: Colors.lightBlueAccent)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  void _cancelDeviceOp(String ip) {
    _cancel.add(ip);
    _setOp(ip, const DeviceOp.busy("Отмена…"));
  }

  /// Помощник: сделать планшет device owner, чтобы обновления ставились молча.
  Future<void> _showDeviceOwnerHelp(SavedDevice dev) async {
    final status = statuses[dev.ip];
    final adbReady = status?.adbOnline == true;
    final directReady = status?.httpAvailable == true;
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: Row(
          children: [
            const Icon(Icons.system_update_outlined,
                color: Colors.orangeAccent, size: 22),
            const SizedBox(width: 10),
            Expanded(
                child: Text("Полное управление: ${dev.name}",
                    style: const TextStyle(fontSize: 16))),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Здесь планшет получает право сам восстановить Wi‑Fi, "
                "перезагрузиться и поставить обновление. Это не просто "
                "подключение к сети.",
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              _ownerStep(
                  '1',
                  'Плеер доступен по Wi‑Fi',
                  directReady,
                  directReady
                      ? 'планшет отвечает'
                      : 'проверьте питание и Wi‑Fi'),
              _ownerStep(
                  '2',
                  'ADB по сети доступен',
                  adbReady,
                  adbReady
                      ? 'можно подтвердить настройку'
                      : 'нужен USB-кабель или уже включённый Wi‑Fi ADB'),
              _ownerStep(
                  '3',
                  'Device Owner назначен',
                  status?.deviceOwner == true,
                  status?.deviceOwner == true
                      ? 'полное управление включено'
                      : 'только на чистом планшете без аккаунтов'),
              const SizedBox(height: 10),
              const Text(
                'Если на планшете уже добавлен Google-аккаунт, Android не даст '
                'назначить владельца. Сначала сбросьте планшет, подключите USB '
                'и выберите «Полное управление по Wi‑Fi» при добавлении.',
                style: TextStyle(color: Colors.orangeAccent, fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text("Закрыть",
                  style: TextStyle(color: Colors.white54))),
          ElevatedButton.icon(
            onPressed: adbReady && status?.deviceOwner != true
                ? () {
                    Navigator.pop(c);
                    _runSetDeviceOwner(dev);
                  }
                : null,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(status?.deviceOwner == true
                ? 'Уже настроен'
                : (adbReady ? 'Назначить владельца' : 'Нужен ADB')),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ownerStep(String number, String title, bool ok, String detail) {
    final color = ok ? Colors.greenAccent : Colors.orangeAccent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: color.withValues(alpha: 0.18),
            child: Text(number, style: TextStyle(color: color, fontSize: 11)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 13)),
              Text(detail,
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ]),
          ),
          Icon(ok ? Icons.check_circle_rounded : Icons.pending_outlined,
              size: 18, color: color),
        ],
      ),
    );
  }

  Future<void> _runSetDeviceOwner(SavedDevice dev) async {
    final ip = dev.ip;
    _setOp(ip, const DeviceOp.busy("Назначаю device owner…"));
    final res = await adb.setDeviceOwner(ip);
    if (res.ok) {
      _setOp(ip, const DeviceOp.success("Device owner ✓"));
      _clearOpLater(ip);
      _refresh(); // обновим /health → бейдж исчезнет
    } else {
      _setOp(ip, const DeviceOp.error("Не удалось"));
      _clearOpLater(ip, after: const Duration(seconds: 8));
      AppLogger.log('set-device-owner ${dev.ip}: ${res.output}');
      if (mounted) {
        showDialog(
          context: context,
          builder: (c) => AlertDialog(
            backgroundColor: const Color(0xFF2C2C2E),
            title: const Text("Не удалось назначить device owner",
                style: TextStyle(fontSize: 16)),
            content: Text(
              "${res.output}\n\nЧаще всего причина — на планшете уже есть "
              "аккаунты. Нужен factory reset, затем команда до добавления "
              "аккаунтов.",
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c), child: const Text("OK")),
            ],
          ),
        );
      }
    }
  }

  /// Сколько проблем с доступами сообщил планшет (только явные false; null —
  /// старый плеер без диагностики, не считаем).
  int _accessIssueCount(DeviceStatus? s) {
    if (s == null) return 0;
    int n = 0;
    if (s.signatureOk == false) n++;
    if (s.canInstall == false) n++;
    if (s.batteryExempt == false) n++;
    if (s.overlay == false) n++;
    return n;
  }

  /// Бейдж «проблемы с доступами» на карточке: появляется, когда плеер сам
  /// сообщил, что чего-то не хватает (подпись/установка/батарея/поверх).
  Widget _accessBadge(SavedDevice dev, DeviceStatus? status) {
    final n = _accessIssueCount(status);
    if (n == 0) return const SizedBox.shrink();
    final critical = status?.signatureOk == false;
    final color = critical ? Colors.redAccent : Colors.orangeAccent.shade100;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: critical
            ? "Чужая подпись APK — обновления не установятся!\n"
                "Нажмите — чек-лист доступов."
            : "Не хватает доступов: $n.\nНажмите — чек-лист и исправление.",
        child: InkWell(
          onTap: () => _showAccessChecklist(dev),
          borderRadius: BorderRadius.circular(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.gpp_maybe_rounded, size: 14, color: color),
              Text("$n",
                  style: TextStyle(
                      fontSize: 10, color: color, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  /// Чек-лист доступов планшета: что плеер сообщил о подписи и разрешениях,
  /// с кнопками «Исправить» по ADB там, где это возможно без рук на планшете.
  Future<void> _showAccessChecklist(SavedDevice dev) async {
    String? busyFix; // ключ фикса, который сейчас выполняется

    await showDialog(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, setLocal) {
        final st = statuses[dev.ip];
        final adbOk = st?.adbOnline ?? false;

        Future<void> runFix(String key) async {
          setLocal(() => busyFix = key);
          final res = await adb.fixAccess(dev.ip, key);
          // Перечитываем /health — чек-лист и бейдж обновятся сразу.
          final fresh = await adb.checkDevice(dev.ip);
          if (mounted) setState(() => statuses[dev.ip] = fresh);
          setLocal(() => busyFix = null);
          if (!res.ok) _toast("Не удалось: ${res.output}", warn: true);
        }

        Widget row(String title, String hint, bool? ok, {String? fixKey}) {
          final icon = ok == null
              ? const Icon(Icons.help_outline_rounded,
                  size: 18, color: Colors.white30)
              : ok
                  ? const Icon(Icons.check_circle_rounded,
                      size: 18, color: Colors.greenAccent)
                  : const Icon(Icons.cancel_rounded,
                      size: 18, color: Colors.redAccent);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                icon,
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13)),
                      Text(ok == null ? "нет данных (старый плеер)" : hint,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white38)),
                    ],
                  ),
                ),
                if (ok == false && fixKey != null)
                  busyFix == fixKey
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton(
                          onPressed: (adbOk && busyFix == null)
                              ? () => runFix(fixKey)
                              : null,
                          child: Text(adbOk ? "Исправить" : "нужен ADB",
                              style: const TextStyle(fontSize: 12)),
                        ),
              ],
            ),
          );
        }

        final sigOk = st?.signatureOk;
        return AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: Row(
            children: [
              const Icon(Icons.gpp_good_rounded,
                  color: Colors.lightBlueAccent, size: 22),
              const SizedBox(width: 10),
              Expanded(
                  child: Text("Доступы: ${dev.name}",
                      style: const TextStyle(fontSize: 16))),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row(
                    "Подпись APK",
                    sigOk == true
                        ? "совпадает с CI-сборкой — обновления совместимы"
                        : "ЧУЖАЯ подпись — обновления поверх не установятся",
                    sigOk),
                if (sigOk == false) ...[
                  const Padding(
                    padding: EdgeInsets.only(left: 28, bottom: 4),
                    child: Text(
                      "Лечение: удалить плеер и поставить заново с ПК "
                      "(ролики в Movies/ads сохранятся):",
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 28, bottom: 6),
                    child: SelectableText(
                      "adb uninstall com.brandmen.ads\nзатем «Обновить APK» из Настроек",
                      style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Colors.lightBlueAccent),
                    ),
                  ),
                ],
                row(
                    "Установка обновлений",
                    "разрешение «Установка неизвестных приложений» — без него "
                        "окно обновления не появится",
                    st?.canInstall,
                    fixKey: 'canInstall'),
                row(
                    "Оптимизация батареи",
                    "исключение из оптимизации — иначе прошивка убивает плеер "
                        "в фоне",
                    st?.batteryExempt,
                    fixKey: 'batteryExempt'),
                row(
                    "Поверх других приложений",
                    "нужно для вывода плеера на экран из фона (бутстрап FSI)",
                    st?.overlay,
                    fixKey: 'overlay'),
                row(
                    "Device owner",
                    st?.deviceOwner == true
                        ? "обновления ставятся молча, права выдаются сами"
                        : "не owner: обновления с подтверждением (это допустимо)",
                    st?.deviceOwner),
                if (st?.deviceOwner == false)
                  Padding(
                    padding: const EdgeInsets.only(left: 28),
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(c);
                        _showDeviceOwnerHelp(dev);
                      },
                      child: const Text("Как сделать device owner…",
                          style: TextStyle(fontSize: 12)),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text("Закрыть",
                    style: TextStyle(color: Colors.white54))),
          ],
        );
      }),
    );
  }

  /// Предупреждение «планшет не ставит обновления сам» (не device owner).
  /// Показывается только если: статус известен и явно false, и включён тумблер
  /// в Настройках. Когда все планшеты провижинены — бейджи исчезают сами, плюс
  /// их можно полностью отключить, чтобы «если всё настроено — не мозолило».
  Widget _autoUpdateBadge(SavedDevice dev, DeviceStatus? status) {
    if (status?.deviceOwner != false) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: AppSettings.showAutoUpdateBadge,
      builder: (_, show, __) {
        if (!show) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Tooltip(
            message: "Не ставит обновления сам (не device owner).\n"
                "Нажмите, чтобы настроить.",
            child: InkWell(
              onTap: () => _showDeviceOwnerHelp(dev),
              borderRadius: BorderRadius.circular(4),
              child: Icon(Icons.system_update_outlined,
                  size: 13, color: Colors.orangeAccent.shade100),
            ),
          ),
        );
      },
    );
  }

  Widget _smallAppleBtn(IconData icon, VoidCallback? onTap,
      {String? tooltip, Color? color}) {
    final enabled = onTap != null;
    final activeColor = color ?? Colors.white70;
    final btn = _HoverBuilder(
      builder: (hovered) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: !enabled
                ? Colors.white.withValues(alpha: 0.02)
                : Colors.white.withValues(alpha: hovered ? 0.14 : 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon,
              size: 18,
              color: !enabled
                  ? Colors.white12
                  : hovered
                      ? Colors.white
                      : activeColor),
        ),
      ),
    );
    // MouseRegion-курсор внутри _HoverBuilder работает только для активной
    // кнопки; для выключенной оставляем обычный курсор.
    final wrapped = enabled
        ? btn
        : MouseRegion(cursor: SystemMouseCursors.basic, child: btn);
    return tooltip != null
        ? Tooltip(message: tooltip, child: wrapped)
        : wrapped;
  }
}

class MediaScreen extends StatefulWidget {
  final bool employeeMode;
  const MediaScreen({super.key, this.employeeMode = true});
  @override
  State<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends State<MediaScreen> {
  List<File> videos = [];
  // Размеры файлов (path → байты), заполняется в _loadVideos: build и каждый
  // элемент списка раньше делали lengthSync() на каждый rebuild — синхронный
  // диск-IO на каждый тик перетаскивания/выбора.
  final Map<String, int> _sizes = {};
  late Directory _videoDir;
  bool _dragging = false;
  String? _customSourceDir;
  // Пути выбранных роликов (галочки) для группового удаления.
  final Set<String> _selected = {};

  static const _orderFileName = '.brandmen_order.json';
  static const _playlistFileName = 'playlist.m3u';
  static const _customDirPrefKey = 'custom_media_dir';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final dir = await MediaConfig.resolveDir();
    _videoDir = Directory(dir);
    final prefs = await SharedPreferences.getInstance();
    _customSourceDir = prefs.getString(_customDirPrefKey);
    await _loadVideos();
  }

  Future<void> _pickSourceFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: "Выберите папку с видеороликами",
    );
    if (dir == null) return;
    await MediaConfig.setCustom(dir);
    setState(() {
      _customSourceDir = dir;
      _videoDir = Directory(dir);
    });
    await _loadVideos();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Папка-источник: $dir"),
        backgroundColor: Colors.green.shade700,
      ));
    }
  }

  Future<void> _resetSourceFolder() async {
    await MediaConfig.setCustom(null);
    final dir = await MediaConfig.resolveDir();
    setState(() {
      _customSourceDir = null;
      _videoDir = Directory(dir);
    });
    await _loadVideos();
  }

  Future<List<String>> _loadSavedOrder() async {
    final orderFile = File(p.join(_videoDir.path, _orderFileName));
    if (!await orderFile.exists()) return [];
    try {
      final list = jsonDecode(await orderFile.readAsString()) as List;
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveOrderAndPlaylist() async {
    final names = videos.map((f) => p.basename(f.path)).toList();

    final orderFile = File(p.join(_videoDir.path, _orderFileName));
    await orderFile.writeAsString(jsonEncode(names));

    final playlistFile = File(p.join(_videoDir.path, _playlistFileName));
    final buf = StringBuffer('#EXTM3U\n');
    for (final n in names) {
      buf.writeln(n);
    }
    await playlistFile.writeAsString(buf.toString());
    AppLogger.log("Плейлист обновлён: ${names.length} файлов");
  }

  Future<void> _loadVideos() async {
    final allOnDisk = _videoDir.listSync().whereType<File>().toList();
    final allNames = allOnDisk.map((f) => p.basename(f.path)).toSet();
    final disk = allOnDisk.where((f) {
      final name = p.basename(f.path);
      final lower = name.toLowerCase();
      if (lower.startsWith('.')) return false;
      if (lower == _playlistFileName) return false;
      // Не показываем исходник, если он уже сконвертирован в mp4.
      if (Transcoder.hasMp4TwinIn(allNames, name)) return false;
      return isVideoFile(lower);
    }).toList();

    final savedOrder = await _loadSavedOrder();
    final byName = {for (final f in disk) p.basename(f.path): f};

    final ordered = <File>[];
    for (final name in savedOrder) {
      final f = byName.remove(name);
      if (f != null) ordered.add(f);
    }
    // Новые файлы добавляются в конец, по дате
    final newOnes = byName.values.toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    ordered.addAll(newOnes);

    // Убираем из выбора пути, которых больше нет на диске.
    final livePaths = ordered.map((f) => f.path).toSet();
    _selected.removeWhere((path) => !livePaths.contains(path));

    final sizes = <String, int>{};
    for (final f in ordered) {
      sizes[f.path] = await f.length();
    }

    if (mounted) {
      setState(() {
        videos = ordered;
        _sizes
          ..clear()
          ..addAll(sizes);
      });
    }
    if (savedOrder.length != ordered.length) {
      await _saveOrderAndPlaylist();
    }
  }

  // Конвертирует не-mp4 ролики в папке в mp4 (для совместимости с Android).
  Future<void> _normalizeMedia() async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text("Обработка видео (конвертация в MP4 при необходимости)..."),
        duration: Duration(seconds: 2),
      ));
    }
    final norm = await Transcoder.normalizeDir(_videoDir.path);
    if (norm.ffmpegMissing && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text(
            "ffmpeg не найден — видео не подготовлены для планшетов. "
            "Установите: brew install ffmpeg"),
        backgroundColor: Colors.orange.shade800,
        duration: const Duration(seconds: 8),
      ));
    } else if (norm.failed.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Не удалось сконвертировать: ${norm.failed.join(', ')}"),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
      ));
    }
  }

  Future<void> _pickVideos() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.video, allowMultiple: true);
    if (result == null) return;
    for (final pathStr in result.paths) {
      if (pathStr != null) {
        await File(pathStr).copy(p.join(_videoDir.path, p.basename(pathStr)));
      }
    }
    await _normalizeMedia();
    await _loadVideos();
    await _saveOrderAndPlaylist();
  }

  Future<void> _deleteVideo(File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text("Удалить видео?"),
        content: Text(p.basename(file.path)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text("Отмена")),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text("Удалить",
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed == true) {
      await file.delete();
      await _loadVideos();
      await _saveOrderAndPlaylist();
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: Text("Удалить $count ${_pluralRoliki(count)}?"),
        content: const Text("Выбранные ролики будут удалены безвозвратно."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text("Отмена")),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text("Удалить",
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true) return;

    final failed = <String>[];
    for (final path in _selected.toList()) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        failed.add(p.basename(path));
      }
    }
    _selected.clear();
    await _loadVideos();
    await _saveOrderAndPlaylist();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failed.isEmpty
            ? "Удалено: $count"
            : "Удалено частично, не удалось: ${failed.join(', ')}"),
        backgroundColor:
            failed.isEmpty ? Colors.green.shade700 : Colors.red.shade700,
      ));
    }
  }

  String _pluralRoliki(int n) {
    final mod10 = n % 10, mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return "ролик";
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
      return "ролика";
    return "роликов";
  }

  void _toggleSelected(String path) {
    setState(() {
      if (!_selected.add(path)) _selected.remove(path);
    });
  }

  void _previewVideo(File file) {
    if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', file.path], runInShell: true);
    } else if (Platform.isMacOS) {
      Process.run('open', [file.path]);
    } else {
      Process.run('xdg-open', [file.path]);
    }
  }

  Future<void> _renameVideo(File file) async {
    final currentName = p.basenameWithoutExtension(file.path);
    final ext = p.extension(file.path);
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text("Переименовать ролик"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            suffixText: ext,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text("Отмена")),
          TextButton(
              onPressed: () => Navigator.pop(c, controller.text.trim()),
              child: const Text("Сохранить")),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == currentName) return;

    final safeName = newName.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    final newPath = p.join(p.dirname(file.path), '$safeName$ext');
    if (await File(newPath).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Файл с именем '$safeName$ext' уже существует"),
          backgroundColor: Colors.red.shade700,
        ));
      }
      return;
    }
    await file.rename(newPath);
    await _loadVideos();
    await _saveOrderAndPlaylist();
  }

  Future<void> _addDroppedFiles(List<String> paths) async {
    int added = 0;
    int skipped = 0;
    for (final path in paths) {
      if (!isVideoFile(path)) {
        skipped++;
        continue;
      }
      final src = File(path);
      if (!await src.exists()) continue;
      final dst = File(p.join(_videoDir.path, p.basename(path)));
      try {
        await src.copy(dst.path);
        added++;
      } catch (_) {}
    }
    if (added > 0) await _normalizeMedia();
    await _loadVideos();
    await _saveOrderAndPlaylist();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            "Добавлено: $added${skipped > 0 ? ", пропущено $skipped (не видео)" : ""}"),
        backgroundColor:
            added > 0 ? Colors.green.shade700 : Colors.orange.shade700,
      ));
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    setState(() {
      final item = videos.removeAt(oldIndex);
      videos.insert(newIndex, item);
    });
    await _saveOrderAndPlaylist();
  }

  @override
  Widget build(BuildContext context) {
    final totalMb = videos.fold<int>(0, (s, f) => s + (_sizes[f.path] ?? 0)) /
        (1024 * 1024);
    final accent = Theme.of(context).colorScheme.primary;
    final pack = BrandPacks.current.value;

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) async {
        setState(() => _dragging = false);
        await _addDroppedFiles(detail.files.map((f) => f.path).toList());
      },
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 32, 36, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 12,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text("Контент",
                            style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -.6)),
                        const SizedBox(height: 4),
                        Text(
                            widget.employeeMode
                                ? "${videos.length} ${_pluralRoliki(videos.length)} готовы к отправке"
                                : "${videos.length} роликов · ${totalMb.toStringAsFixed(1)} МБ · пакет ${pack.version}",
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 13)),
                      ],
                    ),
                    Wrap(
                      spacing: 12,
                      children: [
                        if (!widget.employeeMode)
                          OutlinedButton.icon(
                            onPressed: _pickSourceFolder,
                            icon: const Icon(Icons.folder_open_rounded),
                            label: const Text("Выбрать папку"),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              side: const BorderSide(color: Colors.white24),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ElevatedButton.icon(
                          onPressed: _pickVideos,
                          icon: const Icon(Icons.add_to_photos_rounded),
                          label: const Text("Добавить ролики"),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: const Color(0xFF101012),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12))),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _sourceFolderBanner(),
                const SizedBox(height: 12),
                _selected.isEmpty ? _tipBanner() : _selectionBar(),
                const SizedBox(height: 20),
                const Text(
                  'КОНТЕНТ ТОЧКИ · ПОРЯДОК ПОКАЗА',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: videos.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.file_download_outlined,
                                  size: 80,
                                  color: Colors.white.withValues(alpha: 0.1)),
                              const SizedBox(height: 16),
                              const Text("Перетащи сюда видеофайлы",
                                  style: TextStyle(
                                      color: Colors.white54, fontSize: 18)),
                              const SizedBox(height: 6),
                              const Text("или нажми «Добавить»",
                                  style: TextStyle(
                                      color: Colors.white24, fontSize: 13)),
                            ],
                          ),
                        )
                      : ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: videos.length,
                          onReorderItem: _reorder,
                          itemBuilder: (context, i) {
                            final file = videos[i];
                            return _videoItem(file, i,
                                key: ValueKey(file.path));
                          },
                        ),
                ),
              ],
            ),
          ),
          if (_dragging)
            Positioned.fill(
              child: Container(
                margin: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  border: Border.all(
                      color: accent, width: 3, style: BorderStyle.solid),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.file_download_rounded,
                          size: 100, color: accent),
                      const SizedBox(height: 20),
                      Text("Отпусти чтобы добавить видео",
                          style: TextStyle(
                              color: accent,
                              fontSize: 24,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tipBanner() {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline, color: accent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "Перетащи видео из Finder сюда • Меняй порядок drag&drop • Галочка = выбрать для удаления",
              style: TextStyle(color: accent, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// Панель массовых действий: появляется, когда отмечен хотя бы один ролик.
  Widget _selectionBar() {
    final allSelected = videos.isNotEmpty && _selected.length == videos.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Checkbox(
            value: allSelected ? true : (_selected.isEmpty ? false : null),
            tristate: true,
            activeColor: Colors.redAccent,
            onChanged: (_) => setState(() {
              if (allSelected) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(videos.map((f) => f.path));
              }
            }),
          ),
          Text("Выбрано: ${_selected.length}",
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          TextButton.icon(
            onPressed: () => setState(_selected.clear),
            icon: const Icon(Icons.close_rounded, size: 16),
            label: const Text("Снять"),
            style: TextButton.styleFrom(foregroundColor: Colors.white60),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _deleteSelected,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: Text("Удалить (${_selected.length})"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceFolderBanner() {
    if (_customSourceDir == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.folder_special_rounded,
              color: Colors.green.shade300, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Источник: $_customSourceDir",
                    style: TextStyle(
                        color: Colors.green.shade200,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
                Text("Файлы из этой папки автоматически попадают в плейлист",
                    style: TextStyle(
                        color: Colors.green.shade100.withValues(alpha: 0.7),
                        fontSize: 11)),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _resetSourceFolder,
            icon: const Icon(Icons.close_rounded, size: 16),
            label: const Text("Сбросить"),
            style: TextButton.styleFrom(foregroundColor: Colors.white60),
          ),
        ],
      ),
    );
  }

  Widget _videoItem(File file, int index, {required Key key}) {
    final sizeMb =
        ((_sizes[file.path] ?? 0) / (1024 * 1024)).toStringAsFixed(1);
    final selected = _selected.contains(file.path);
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: selected
            ? Colors.redAccent.withValues(alpha: 0.1)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: selected
                ? Colors.redAccent.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          Checkbox(
            value: selected,
            activeColor: Colors.redAccent,
            onChanged: (_) => _toggleSelected(file.path),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
              child: const Icon(Icons.drag_indicator_rounded,
                  color: Colors.white24, size: 20),
            ),
          ),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              "${index + 1}",
              style: const TextStyle(
                  color: Colors.blue,
                  fontWeight: FontWeight.bold,
                  fontSize: 13),
            ),
          ),
          const SizedBox(width: 14),
          const Icon(Icons.movie_creation_outlined,
              color: Colors.white54, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  p.basename(file.path),
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
                Text("$sizeMb MB",
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.play_circle_outline_rounded,
                color: Colors.blue),
            tooltip: "Открыть",
            onPressed: () => _previewVideo(file),
          ),
          IconButton(
            icon: const Icon(Icons.edit_rounded, color: Colors.white60),
            tooltip: "Переименовать",
            onPressed: () => _renameVideo(file),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded,
                color: Colors.redAccent),
            tooltip: "Удалить",
            onPressed: () => _deleteVideo(file),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _timeController = TextEditingController(text: "22:00");
  final _logUrlController = TextEditingController();
  final _logTokenController = TextEditingController();
  bool autoOffEnabled = false;
  bool autoStartEnabled = false;
  String? localIp;
  List<SavedDevice> savedDevices = [];

  bool _pairingActive = false;
  int _pairingSecondsLeft = 0;
  final Set<String> _connectingIps = {};
  Timer? _pairingTimer;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _getHostIp();
    _loadDevices();
    _loadAutoStart();
  }

  @override
  void dispose() {
    _pairingTimer?.cancel();
    _logUrlController.dispose();
    _logTokenController.dispose();
    super.dispose();
  }

  /// Ключи настроек сервера логов (читаются и во вкладке «Логи» при отправке).
  static const kLogServerUrlKey = 'log_server_url';
  static const kLogServerTokenKey = 'log_server_token';

  Future<void> _persistLogServer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLogServerUrlKey, _logUrlController.text.trim());
    await prefs.setString(kLogServerTokenKey, _logTokenController.text.trim());
  }

  void _startPairing() {
    const seconds = 30;
    BrandmenServer.instance
        ?.startPairing(duration: const Duration(seconds: seconds));
    setState(() {
      _pairingActive = true;
      _pairingSecondsLeft = seconds;
    });
    _pairingTimer?.cancel();
    _pairingTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _pairingSecondsLeft--);
      if (_pairingSecondsLeft <= 0) _stopPairing();
    });
  }

  void _stopPairing() {
    _pairingTimer?.cancel();
    BrandmenServer.instance?.stopPairing();

    if (mounted) {
      setState(() {
        _pairingActive = false;
        _pairingSecondsLeft = 0;
      });
    }
  }

  Future<void> _loadAutoStart() async {
    final enabled = await AutoStart.isEnabled();
    if (mounted) setState(() => autoStartEnabled = enabled);
  }

  Future<void> _toggleAutoStart(bool value) async {
    final ok = value ? await AutoStart.enable() : await AutoStart.disable();
    if (!mounted) return;
    if (ok) {
      setState(() => autoStartEnabled = value);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(value ? "Автозапуск включён" : "Автозапуск отключён"),
        backgroundColor: Colors.blue.shade700,
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Не удалось изменить автозапуск"),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  Future<void> _exportBackup() async {
    final path = await BackupManager.export();
    if (!mounted) return;
    if (path != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Бэкап сохранён: $path"),
        backgroundColor: Colors.green.shade700,
      ));
    }
  }

  Future<void> _importBackup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text("Импорт бэкапа?"),
        content: const Text(
            "Текущие настройки и список планшетов будут перезаписаны.\n\nВидеофайлы не затрагиваются."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text("Отмена")),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text("Импортировать",
                  style: TextStyle(color: Colors.orange))),
        ],
      ),
    );
    if (confirmed != true) return;
    final count = await BackupManager.import();
    if (!mounted) return;
    if (count != null) {
      await _loadSettings();
      await _loadDevices();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Восстановлено: $count планшетов"),
        backgroundColor: Colors.green.shade700,
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Не удалось импортировать"),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  Future<void> _loadDevices() async {
    final list = await DeviceStorage.load();
    if (mounted) setState(() => savedDevices = list);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _timeController.text = prefs.getString('autoOffTime') ?? "22:00";
        autoOffEnabled = prefs.getBool('autoOffEnabled') ?? false;
        _logUrlController.text =
            effectiveLogServerUrl(prefs.getString(kLogServerUrlKey));
        _logTokenController.text =
            prefs.getString(kLogServerTokenKey) ?? kDefaultLogServerToken;
      });
    }
  }

  /// Тихо сохраняет настройки авто-выключения при каждом изменении —
  /// без кнопки «Сохранить» и без всплывашки.
  Future<void> _persistAutoOff() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('autoOffTime', _timeController.text);
    await prefs.setBool('autoOffEnabled', autoOffEnabled);
  }

  Future<void> _getHostIp() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            if (mounted) setState(() => localIp = addr.address);
            return;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _renameDevice(SavedDevice dev) async {
    final controller = TextEditingController(text: dev.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text("Переименовать планшет"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text("Отмена")),
          TextButton(
              onPressed: () => Navigator.pop(c, controller.text.trim()),
              child: const Text("Сохранить")),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      await DeviceStorage.rename(dev.ip, newName);
      _loadDevices();
    }
  }

  Future<void> _connectAdb(SavedDevice dev) async {
    if (_connectingIps.contains(dev.ip)) return;
    setState(() => _connectingIps.add(dev.ip));
    final adb = AdbManager();
    final status = await adb.checkDevice(dev.ip);
    if (!mounted) return;
    setState(() => _connectingIps.remove(dev.ip));
    if (status.adbOnline) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${dev.name}: ADB подключён (${dev.ip}:5555)'),
        backgroundColor: Colors.green.shade700,
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '${dev.name}: не удалось подключить ADB.\n'
          'Убедитесь что на планшете включён режим разработчика и отладка по WiFi.',
        ),
        backgroundColor: Colors.orange.shade700,
        duration: const Duration(seconds: 6),
      ));
    }
  }

  Future<void> _removeDevice(SavedDevice dev) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text("Удалить планшет?"),
        content: Text("${dev.name} (${dev.ip})"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text("Отмена")),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text("Удалить",
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed == true) {
      await DeviceStorage.remove(dev.ip);
      _loadDevices();
    }
  }

  Future<void> _checkUpdate() async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text("Проверяю обновления..."),
      duration: Duration(seconds: 2),
    ));
    final info = await AppUpdater.checkForUpdate();
    if (!mounted) return;
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("У вас последняя версия ($kAppVersion)"),
        backgroundColor: Colors.green.shade700,
      ));
      return;
    }
    final mainState = context.findAncestorStateOfType<_MainScreenState>();
    mainState?._showUpdateDialog(info);
  }

  Future<void> _checkAndUpdateApk() async {
    // IP планшета может поменяться после переподключения к другой Wi‑Fi сети.
    // Всегда начинаем операцию со свежих данных, а не с UI-кэша вкладки.
    final latestDevices = await DeviceStorage.load();
    if (!mounted) return;
    setState(() => savedDevices = latestDevices);

    final status = ValueNotifier<String>('');
    final progress =
        ValueNotifier<double?>(null); // null = крутилка, 0..1 = прогрессбар

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => ValueListenableBuilder<String>(
        valueListenable: status,
        builder: (_, msg, __) => ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, pval, __) => AlertDialog(
            backgroundColor: const Color(0xFF2C2C2E),
            title: const Row(
              children: [
                Icon(Icons.android_rounded,
                    color: Colors.greenAccent, size: 20),
                SizedBox(width: 10),
                Text('Обновление APK', style: TextStyle(fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (pval == null)
                    const LinearProgressIndicator(
                      backgroundColor: Colors.white12,
                      color: Colors.greenAccent,
                    )
                  else
                    LinearProgressIndicator(
                      value: pval,
                      backgroundColor: Colors.white12,
                      color: Colors.greenAccent,
                    ),
                  const SizedBox(height: 12),
                  Text(msg,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    void close() {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    void fail(String msg) {
      close();
      status.dispose();
      progress.dispose();
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: const Row(children: [
            Icon(Icons.error_outline_rounded, color: Colors.redAccent),
            SizedBox(width: 10),
            Text('Ошибка', style: TextStyle(fontSize: 16)),
          ]),
          content: Text(msg,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('OK'))
          ],
        ),
      );
    }

    // ── Шаг 1: опрос планшетов ────────────────────────────────────────────
    String lowestVersion = '99.99.99';
    final Map<String, String> deviceVersions = {}; // ip → version
    final List<String> reachableIps = [];

    for (int i = 0; i < savedDevices.length; i++) {
      final dev = savedDevices[i];
      status.value =
          '(${i + 1}/${savedDevices.length}) ${dev.name}\nОпрашиваю ${dev.ip}...';
      final ver = await AdbManager.getApkVersion(dev.ip);
      if (ver != null) {
        reachableIps.add(dev.ip);
        deviceVersions[dev.ip] = ver;
        final p1 = ver.split('.').map((s) => int.tryParse(s) ?? 0).toList();
        final pl =
            lowestVersion.split('.').map((s) => int.tryParse(s) ?? 0).toList();
        bool isLower = false;
        for (int j = 0; j < 3; j++) {
          final v1 = j < p1.length ? p1[j] : 0;
          final vl = j < pl.length ? pl[j] : 0;
          if (v1 < vl) {
            isLower = true;
            break;
          }
          if (v1 > vl) break;
        }
        if (isLower) lowestVersion = ver;
      }
    }

    if (!mounted) {
      status.dispose();
      progress.dispose();
      return;
    }

    if (reachableIps.isEmpty) {
      fail(
          'Ни один планшет не ответил на HTTP-запрос (порт 5011).\n\nУбедитесь что Brandmen Ads запущен и планшет в той же сети.');
      return;
    }

    // ── Шаг 2: проверка GitHub ─────────────────────────────────────────────
    final currentVersion =
        lowestVersion == '99.99.99' ? '0.0.0' : lowestVersion;
    final devList = reachableIps.map((ip) {
      final name = savedDevices
          .firstWhere((d) => d.ip == ip,
              orElse: () => SavedDevice(ip: ip, name: ip))
          .name;
      return '$name: v${deviceVersions[ip]}';
    }).join('\n');

    status.value =
        'Найдено ${reachableIps.length} планшетов:\n$devList\n\nПроверяю GitHub...';

    final apkInfo =
        await AppUpdater.checkApkUpdate(currentApkVersion: currentVersion);
    if (!mounted) {
      status.dispose();
      progress.dispose();
      return;
    }

    if (apkInfo == null) {
      close();
      status.dispose();
      progress.dispose();
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: const Row(children: [
            Icon(Icons.check_circle_rounded, color: Colors.greenAccent),
            SizedBox(width: 10),
            Text('Всё актуально', style: TextStyle(fontSize: 16)),
          ]),
          content: Text('APK v$currentVersion — последняя версия.\n\n$devList',
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('OK'))
          ],
        ),
      );
      return;
    }

    // ── Шаг 3: подтверждение ─────────────────────────────────────────────
    close();
    status.dispose();

    if (!mounted) {
      progress.dispose();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: Row(
          children: [
            const Icon(Icons.system_update_rounded,
                color: Colors.greenAccent, size: 22),
            const SizedBox(width: 10),
            Text('APK v${apkInfo.version}'),
          ],
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Новая версия найдена на GitHub.',
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              Text(devList,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 4),
              Text('→ v${apkInfo.version}',
                  style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Отмена',
                  style: TextStyle(color: Colors.white54))),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(c, true),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text('Обновить ${reachableIps.length} планшетов'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.greenAccent,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      progress.dispose();
      return;
    }

    // ── Шаг 4: скачивание ─────────────────────────────────────────────────
    final dlStatus =
        ValueNotifier<String>('Скачиваю APK v${apkInfo.version}...');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => ValueListenableBuilder<String>(
        valueListenable: dlStatus,
        builder: (_, msg, __) => ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, pval, __) => AlertDialog(
            backgroundColor: const Color(0xFF2C2C2E),
            title: const Row(children: [
              Icon(Icons.android_rounded, color: Colors.greenAccent, size: 20),
              SizedBox(width: 10),
              Text('Установка APK', style: TextStyle(fontSize: 16)),
            ]),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: pval,
                    backgroundColor: Colors.white12,
                    color: Colors.greenAccent,
                  ),
                  const SizedBox(height: 12),
                  Text(msg,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    progress.value = null;
    final apkFile = await AppUpdater.downloadApk(apkInfo, (v) {
      progress.value = v;
      dlStatus.value =
          'Скачиваю APK v${apkInfo.version}... ${(v * 100).round()}%';
    });

    if (!mounted) {
      progress.dispose();
      dlStatus.dispose();
      return;
    }

    if (apkFile == null) {
      Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
      dlStatus.dispose();
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: const Row(children: [
            Icon(Icons.error_outline_rounded, color: Colors.redAccent),
            SizedBox(width: 10),
            Text('Ошибка загрузки', style: TextStyle(fontSize: 16)),
          ]),
          content: const Text(
              'Не удалось скачать APK с GitHub.\n\nПроверьте интернет-соединение.',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('OK'))
          ],
        ),
      );
      return;
    }

    // ── Шаг 5: установка (авто через ADB + копия в «Загрузки») ─────────────
    final adb = AdbManager();
    final List<String> autoInstalled = [];
    final List<String> dialogShown = [];
    final List<String> manualNeeded = [];
    final List<String> failed = [];

    for (int i = 0; i < reachableIps.length; i++) {
      final ip = reachableIps[i];
      final devName = savedDevices
          .firstWhere((d) => d.ip == ip,
              orElse: () => SavedDevice(ip: ip, name: ip))
          .name;
      progress.value = (i + 1) / reachableIps.length;
      dlStatus.value =
          'Устанавливаю на $devName\n(${i + 1}/${reachableIps.length})...';
      final res = await adb.installApk(ip, apkFile.path);
      switch (res) {
        case ApkInstallResult.installed:
          autoInstalled.add(devName);
          break;
        case ApkInstallResult.dialogShown:
          dialogShown.add(devName);
          break;
        case ApkInstallResult.pushedToDownloads:
          manualNeeded.add(devName);
          break;
        case ApkInstallResult.failed:
          failed.add(devName);
          break;
      }
    }

    await apkFile.delete().catchError((_) => apkFile);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    dlStatus.dispose();

    if (!mounted) return;

    final lines = <Widget>[];
    if (autoInstalled.isNotEmpty) {
      lines.add(_resultLine(Icons.check_circle_rounded, Colors.greenAccent,
          'Установлено автоматически', autoInstalled.join(', ')));
    }
    if (dialogShown.isNotEmpty) {
      lines.add(_resultLine(
          Icons.system_update_rounded,
          Colors.lightBlueAccent,
          'Окно установки открыто на планшете — подойдите и тапните «Установить/Обновить»',
          dialogShown.join(', ')));
    }
    if (manualNeeded.isNotEmpty) {
      lines.add(_resultLine(
          Icons.download_done_rounded,
          Colors.orange,
          'Файл в «Загрузках» — установите вручную (тап по BrandmenAds.apk)',
          manualNeeded.join(', ')));
    }
    if (failed.isNotEmpty) {
      lines.add(_resultLine(Icons.error_outline_rounded, Colors.redAccent,
          'Ошибка', failed.join(', ')));
    }

    final allAuto = manualNeeded.isEmpty && failed.isEmpty;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: Row(children: [
          Icon(
              allAuto ? Icons.check_circle_rounded : Icons.info_outline_rounded,
              color: allAuto ? Colors.greenAccent : Colors.orange,
              size: 22),
          const SizedBox(width: 10),
          Text('APK v${apkInfo.version}', style: const TextStyle(fontSize: 16)),
        ]),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lines,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))
        ],
      ),
    );
  }

  Widget _resultLine(IconData icon, Color color, String title, String devices) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(devices,
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addManually() async {
    final controller = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text("Добавить планшет вручную"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: "192.168.x.x", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text("Отмена")),
          TextButton(
              onPressed: () => Navigator.pop(c, controller.text.trim()),
              child: const Text("Добавить")),
        ],
      ),
    );
    if (ip != null && RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip)) {
      await DeviceStorage.add(ip, name: "Планшет ${savedDevices.length + 1}");
      _loadDevices();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(40.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Настройки",
              style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
          const SizedBox(height: 30),
          _sectionCard("Сеть", [
            _settingRow(
                "IP этого Mac",
                SelectableText(localIp ?? "...",
                    style: const TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                        fontSize: 16))),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
              ),
              child: Text(
                "На планшете в Brandmen Ads → ⚙️ ввести ТОЛЬКО IP (без :5010), порт добавляется автоматически",
                style: TextStyle(color: Colors.blue.shade200, fontSize: 12),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          _sectionCard("Автоматизация", [
            _settingRow(
                "Автоматическое выключение",
                Switch(
                    value: autoOffEnabled,
                    activeThumbColor: Colors.blue,
                    onChanged: (v) {
                      setState(() => autoOffEnabled = v);
                      _persistAutoOff();
                    })),
            if (autoOffEnabled) ...[
              const SizedBox(height: 12),
              _settingRow(
                  "Время (ЧЧ:ММ)",
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: _timeController,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(
                          isDense: true, border: OutlineInputBorder()),
                      onChanged: (_) => _persistAutoOff(),
                    ),
                  )),
            ],
            const Divider(height: 32, color: Colors.white10),
            _settingRow(
                "Запускать при входе в систему",
                Switch(
                    value: autoStartEnabled,
                    activeThumbColor: Colors.blue,
                    onChanged: _toggleAutoStart)),
            const Divider(height: 32, color: Colors.white10),
            _settingRow(
                "Показывать бейдж авто-обновления",
                ValueListenableBuilder<bool>(
                  valueListenable: AppSettings.showAutoUpdateBadge,
                  builder: (_, value, __) => Switch(
                      value: value,
                      activeThumbColor: Colors.blue,
                      onChanged: (v) => AppSettings.setShowAutoUpdateBadge(v)),
                )),
          ]),
          const SizedBox(height: 20),
          _sectionCard("Режим разработчика", [
            _settingRow(
                "Показать техническое управление",
                ValueListenableBuilder<bool>(
                  valueListenable: AppSettings.developerMode,
                  builder: (_, value, __) => Switch(
                      value: value,
                      activeThumbColor: Colors.orange,
                      onChanged: (v) => AppSettings.setDeveloperMode(v)),
                )),
            const SizedBox(height: 8),
            const Text(
              "Включает в карточках планшетов ребут, статусы (owner/онлайн/версия) "
              "и диагностику. Для персонала держите выключенным — управление проще.",
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ]),
          const SizedBox(height: 20),
          _sectionCard("Сервер логов (диагностика)", [
            const Text(
              "Адрес сервера, куда вкладка «Логи» отправляет лог по кнопке. "
              "Оставьте пустым, если отправка не нужна.",
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _logUrlController,
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => _persistLogServer(),
              decoration: const InputDecoration(
                isDense: true,
                labelText: "Адрес (https://...)",
                hintText: "https://api.example.com",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _logTokenController,
              style: const TextStyle(fontSize: 13),
              obscureText: true,
              onChanged: (_) => _persistLogServer(),
              decoration: const InputDecoration(
                isDense: true,
                labelText: "Ключ (Bearer-токен, необязательно)",
                border: OutlineInputBorder(),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          _sectionCard("О программе", [
            _settingRow(
              "Версия",
              const Text(kAppVersion,
                  style: TextStyle(color: Colors.white54, fontSize: 14)),
            ),
            const SizedBox(height: 4),
            const Text(
              "Управление рекламными планшетами по WiFi через ADB и HTTP · 2026",
              style: TextStyle(color: Colors.white24, fontSize: 11),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                onPressed: _checkUpdate,
                icon: const Icon(Icons.system_update_rounded, size: 18),
                label: const Text("Проверить обновления"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blue,
                  side: const BorderSide(color: Colors.blue),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                onPressed: savedDevices.isEmpty ? null : _checkAndUpdateApk,
                icon: const Icon(Icons.android_rounded, size: 18),
                label: const Text("Обновить APK на планшетах"),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.greenAccent,
                  side: const BorderSide(color: Colors.greenAccent),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          _sectionCard("Резервное копирование", [
            const Text(
              "Экспорт сохраняет список планшетов, расписание и пути к папкам в один JSON-файл.\nИмпорт переносит настройки на другой Mac/Windows.",
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _exportBackup,
                    icon: const Icon(Icons.file_download_outlined, size: 18),
                    label: const Text("Экспорт"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _importBackup,
                    icon: const Icon(Icons.file_upload_outlined, size: 18),
                    label: const Text("Импорт"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange,
                      side: const BorderSide(color: Colors.orange),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ]),
          const SizedBox(height: 20),
          _sectionCard("Планшеты (${savedDevices.length})", [
            ...savedDevices.map((dev) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.tablet_android_rounded,
                          color: Colors.white38, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(dev.name,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w500)),
                            Text(dev.ip,
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.white38)),
                          ],
                        ),
                      ),
                      Tooltip(
                        message: 'Подключить ADB по WiFi',
                        child: _connectingIps.contains(dev.ip)
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: Padding(
                                  padding: EdgeInsets.all(11),
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.blue),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(Icons.wifi_tethering_rounded,
                                    color: Colors.blue, size: 18),
                                onPressed: () => _connectAdb(dev),
                              ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_rounded,
                            color: Colors.white54, size: 18),
                        onPressed: () => _renameDevice(dev),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded,
                            color: Colors.redAccent, size: 18),
                        onPressed: () => _removeDevice(dev),
                      ),
                    ],
                  ),
                )),
            if (savedDevices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text("Нет сохранённых планшетов",
                    style: TextStyle(color: Colors.white38)),
              ),
            const SizedBox(height: 8),
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              decoration: BoxDecoration(
                color: _pairingActive
                    ? Colors.blue.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _pairingActive ? Colors.blue : Colors.transparent,
                  width: 1,
                ),
              ),
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                leading: Icon(
                  _pairingActive
                      ? Icons.bluetooth_searching_rounded
                      : Icons.link_rounded,
                  color: _pairingActive ? Colors.blue : Colors.white54,
                ),
                title: Text(
                  _pairingActive
                      ? 'Ожидаю планшет... $_pairingSecondsLeft с'
                      : 'Режим сопряжения',
                  style: TextStyle(
                    color: _pairingActive ? Colors.blue : Colors.white70,
                    fontSize: 14,
                  ),
                ),
                subtitle: Text(
                  _pairingActive
                      ? 'Нажмите "Найти" на планшете'
                      : 'Нажмите, затем запустите поиск на планшете',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                trailing: _pairingActive
                    ? TextButton(
                        onPressed: _stopPairing,
                        child: const Text('Отмена',
                            style: TextStyle(color: Colors.white38)),
                      )
                    : null,
                onTap: _pairingActive ? null : _startPairing,
              ),
            ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: _addManually,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text("Добавить вручную по IP"),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white24),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _sectionCard(String title, List<Widget> children) {
    return Container(
      width: 700,
      padding: const EdgeInsets.all(25),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.white54,
                  letterSpacing: 1.5)),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _settingRow(String label, Widget control) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 14, color: Colors.white70))),
        control,
      ],
    );
  }
}

/// Вкладка «Логи» — сервисный режим: живой поток событий приложения прямо в
/// окне (из буфера AppLogger), без открытия файла. Автопрокрутка, фильтр,
/// копирование, очистка буфера и открытие файла лога.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});
  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final _scroll = ScrollController();
  final _filterCtrl = TextEditingController();
  String _query = '';
  bool _autoScroll = true;
  bool _sending = false;

  void _snack(String msg, {bool warn = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor:
            warn ? Colors.orange.shade800 : const Color(0xFF333335),
        duration: const Duration(seconds: 4),
      ));
  }

  Future<void> _sendLog() async {
    final prefs = await SharedPreferences.getInstance();
    final urlPref =
        (prefs.getString(_SettingsScreenState.kLogServerUrlKey) ?? '').trim();
    final tokenPref =
        (prefs.getString(_SettingsScreenState.kLogServerTokenKey) ?? '').trim();
    final url = effectiveLogServerUrl(urlPref);
    final token = tokenPref.isEmpty ? kDefaultLogServerToken : tokenPref;
    if (url.trim().isEmpty) {
      _snack("Укажите адрес сервера логов в Настройках", warn: true);
      return;
    }
    setState(() => _sending = true);
    final res = await LogUploader.send(baseUrl: url, token: token);
    if (!mounted) return;
    setState(() => _sending = false);
    _snack(
        res.ok ? "Лог отправлен: ${res.message}" : "Не удалось: ${res.message}",
        warn: !res.ok);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  List<String> get _filtered {
    final all = AppLogger.lines;
    if (_query.isEmpty) return all;
    final q = _query.toLowerCase();
    return all.where((l) => l.toLowerCase().contains(q)).toList();
  }

  Color _colorFor(String line) {
    final l = line.toLowerCase();
    if (l.contains('ошибк') ||
        l.contains('error') ||
        l.contains('не удал') ||
        l.contains('exception')) {
      return Colors.redAccent.shade100;
    }
    if (l.contains('[upd]') || l.contains('обновл'))
      return Colors.lightBlueAccent;
    if (l.contains('push') ||
        l.contains('sync') ||
        l.contains('синхрон') ||
        l.contains('загружено') ||
        l.contains('запущ')) {
      return Colors.greenAccent.shade100;
    }
    return Colors.white60;
  }

  void _maybeAutoScroll() {
    if (!_autoScroll || !_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _openFile() async {
    final path = AppLogger.logPath;
    if (path == null) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,$path']);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else {
        await Process.run('xdg-open', [File(path).parent.path]);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text("Логи",
                  style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1)),
              const SizedBox(width: 10),
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text("сервисный режим",
                    style: TextStyle(color: Colors.white38, fontSize: 13)),
              ),
              const Spacer(),
              // Автопрокрутка
              Row(
                children: [
                  const Text("Автопрокрутка",
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                  Switch(
                    value: _autoScroll,
                    activeThumbColor: Colors.blue,
                    onChanged: (v) {
                      setState(() => _autoScroll = v);
                      _maybeAutoScroll();
                    },
                  ),
                ],
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: "Отправить лог на сервер",
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.lightBlueAccent))
                    : const Icon(Icons.cloud_upload_rounded,
                        color: Colors.lightBlueAccent),
                onPressed: _sending ? null : _sendLog,
              ),
              IconButton(
                tooltip: "Копировать всё",
                icon: const Icon(Icons.copy_all_rounded, color: Colors.white54),
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: AppLogger.lines.join('\n')));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text("Лог скопирован"),
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 2),
                  ));
                },
              ),
              IconButton(
                tooltip: "Очистить экран (файл не трогается)",
                icon: const Icon(Icons.delete_sweep_rounded,
                    color: Colors.white54),
                onPressed: () => AppLogger.clearBuffer(),
              ),
              IconButton(
                tooltip: "Открыть файл лога",
                icon: const Icon(Icons.folder_open_rounded,
                    color: Colors.white54),
                onPressed: _openFile,
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _filterCtrl,
            style: const TextStyle(fontSize: 13),
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              hintText: "Фильтр (например: sync, UPD, 192.168, ошибка)",
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.04),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: ValueListenableBuilder<int>(
                valueListenable: AppLogger.revision,
                builder: (_, __, ___) {
                  final lines = _filtered;
                  _maybeAutoScroll();
                  if (lines.isEmpty) {
                    return const Center(
                      child: Text("Пока пусто — события появятся здесь",
                          style:
                              TextStyle(color: Colors.white24, fontSize: 13)),
                    );
                  }
                  // SelectionArea + Text вместо SelectableText на каждую
                  // строку: SelectableText — тяжёлый виджет, тысячи штук
                  // заметно тормозили rebuild при потоке логов. Выделение
                  // (в т.ч. через несколько строк) работает через область.
                  return Scrollbar(
                    controller: _scroll,
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        itemCount: lines.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            lines[i],
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: _colorFor(lines[i]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<int>(
            valueListenable: AppLogger.revision,
            builder: (_, __, ___) => Text(
              "${_filtered.length} строк${_query.isEmpty ? "" : " (фильтр)"} · буфер ${AppLogger.lines.length}",
              style: const TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
