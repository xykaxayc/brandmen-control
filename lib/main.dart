import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:desktop_drop/desktop_drop.dart';

import 'server.dart';
import 'discovery.dart';
import 'adb_manager.dart';
import 'logger.dart';
import 'tray_manager.dart';
import 'device_storage.dart';
import 'media_config.dart';
import 'transcoder.dart';
import 'backup_manager.dart';
import 'autostart.dart';
import 'updater.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();
  await _startServer();
  runApp(const BrandmenApp());
}

BrandmenServer? globalServer;

Future<void> _startServer() async {
  try {
    await MediaConfig.resolveDir();
    globalServer = BrandmenServer();
    await globalServer!.start();
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
    return MaterialApp(
      title: 'Brandmen Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'Segoe UI',
        scaffoldBackgroundColor: Colors.transparent,
        useMaterial3: true,
      ),
      home: const AppleBackgroundWrapper(child: MainScreen()),
    );
  }
}

class AppleBackgroundWrapper extends StatelessWidget {
  final Widget child;
  const AppleBackgroundWrapper({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2C2C2E), Color(0xFF1C1C1E)],
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
  int _selectedIndex = 0;
  Timer? _schedulerTimer;
  String? _lastTriggerMinute;
  final adb = AdbManager();
  final tray = TrayManager();
  StreamSubscription<DeviceRegistration>? _regSub;
  final _settingsKey = GlobalKey<_SettingsScreenState>();
  final _dashboardKey = GlobalKey<_DashboardScreenState>();

  @override
  void initState() {
    super.initState();
    _startScheduler();
    _cleanupOnStart();
    tray.init(() {
      if (mounted) setState(() {});
    });
    _checkForUpdate();
    _regSub = globalServer?.onDeviceRegistered.listen(_onDeviceRegistered);
  }

  Future<void> _onDeviceRegistered(DeviceRegistration reg) async {
    await DeviceStorage.add(reg.ip, name: reg.name);
    globalServer?.stopPairing();
    _settingsKey.currentState?._stopPairing();
    // Устанавливаем ADB-соединение по WiFi сразу после сопряжения
    adb.checkDevice(reg.ip);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Планшет добавлен: ${reg.name} (${reg.ip})'),
      backgroundColor: Colors.green.shade700,
      duration: const Duration(seconds: 5),
    ));
    // Переходим на вкладку Планшеты — там карточки с управлением
    setState(() => _selectedIndex = 0);
    _dashboardKey.currentState?._refresh();
  }

  Future<void> _checkForUpdate() async {
    await Future.delayed(const Duration(seconds: 5));
    final info = await AppUpdater.checkForUpdate();
    if (info == null || !mounted) return;
    _showUpdateDialog(info);
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog(
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
    );
  }

  void _runUpdate(UpdateInfo info) {
    double progress = 0;
    String status = '';
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) {
          return AlertDialog(
            backgroundColor: const Color(0xFF2C2C2E),
            title: const Text('Обновление...'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: progress,
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

    AppUpdater.downloadAndApply(info, (p, s) {
      if (mounted) {
        setState(() {
          progress = p;
          status = s;
        });
      }
    }).then((ok) {
      if (!ok && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              const Text('Не удалось обновить. Скачайте вручную с GitHub.'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 6),
        ));
      }
    });
  }

  Future<void> _cleanupOnStart() async {
    await adb.cleanupOffline();
  }

  @override
  void dispose() {
    _schedulerTimer?.cancel();
    _regSub?.cancel();
    super.dispose();
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
    final List<Widget> screens = [
      DashboardScreen(key: _dashboardKey),
      const MediaScreen(),
      SettingsScreen(key: _settingsKey),
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Row(
        children: [
          Container(
            width: 220,
            padding: const EdgeInsets.symmetric(vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              border: const Border(right: BorderSide(color: Colors.white10)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 30),
                const Text("Brandmen",
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
                const Text("CONTROL",
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                        letterSpacing: 2)),
                const SizedBox(height: 50),
                _navItem(0, Icons.grid_view_rounded, "Планшеты"),
                _navItem(1, Icons.play_circle_fill_rounded, "Медиатека"),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton(
                    onPressed: () {
                      AppLogger.log("Сворачивание в трей");
                      tray.hideToTray();
                    },
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.unfold_less_rounded,
                            size: 16, color: Colors.white38),
                        SizedBox(width: 8),
                        Text("В трей",
                            style:
                                TextStyle(color: Colors.white38, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _navItem(2, Icons.tune_rounded, "Настройки"),
                const SizedBox(height: 10),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _HoverBuilder(
        builder: (hovered) => InkWell(
          onTap: () => setState(() => _selectedIndex = index),
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: active
                  ? Colors.blue.withValues(alpha: 0.15)
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
                      color: active ? Colors.blue : Colors.white60, size: 20),
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
                      fontWeight:
                          active ? FontWeight.w600 : FontWeight.normal),
                  child: Text(label),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _BulkSyncProgress {
  final int currentIndex;
  final int totalDevices;
  final String currentDevice;
  final String currentStep;
  final Map<String, String> deviceStates;

  const _BulkSyncProgress({
    required this.currentIndex,
    required this.totalDevices,
    required this.currentDevice,
    required this.currentStep,
    required this.deviceStates,
  });

  _BulkSyncProgress copyWith({
    int? currentIndex,
    int? totalDevices,
    String? currentDevice,
    String? currentStep,
    Map<String, String>? deviceStates,
  }) {
    return _BulkSyncProgress(
      currentIndex: currentIndex ?? this.currentIndex,
      totalDevices: totalDevices ?? this.totalDevices,
      currentDevice: currentDevice ?? this.currentDevice,
      currentStep: currentStep ?? this.currentStep,
      deviceStates: deviceStates ?? this.deviceStates,
    );
  }

  _BulkSyncProgress updateDevice(
    String name,
    String state, {
    int? currentIndex,
    String? currentDevice,
    String? currentStep,
  }) {
    return copyWith(
      currentIndex: currentIndex,
      currentDevice: currentDevice,
      currentStep: currentStep,
      deviceStates: {...deviceStates, name: state},
    );
  }
}

class _DashboardScreenState extends State<DashboardScreen> {
  final adb = AdbManager();
  List<SavedDevice> saved = [];
  Map<String, DeviceStatus> statuses = {};
  Timer? _screenshotTimer;
  final Map<String, String> _thumbnails = {};
  bool _isLoading = false;
  bool _isRegistering = false;
  // Идёт длительная операция (синк/запуск/завершение смены). Блокирует кнопки,
  // чтобы две операции не дрались за один WiFi-канал и ADB одновременно.
  bool _busy = false;

  /// Выполняет операцию монопольно: пока она идёт, кнопки действий выключены.
  Future<void> _guard(Future<void> Function() op) async {
    if (_busy) return;
    if (mounted) setState(() => _busy = true);
    try {
      await op();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _screenshotTimer =
        Timer.periodic(const Duration(minutes: 5), (timer) => _captureAll());
  }

  @override
  void dispose() {
    _screenshotTimer?.cancel();
    super.dispose();
  }

  Future<void> _captureAll() async {
    final tempDir = await getTemporaryDirectory();
    // Параллельно: раньше скриншоты снимались по очереди через ADB screencap,
    // и refresh с несколькими планшетами заметно подвисал.
    await Future.wait(saved.where((d) => statuses[d.ip]?.online == true).map(
      (dev) async {
        final path =
            p.join(tempDir.path, "thumb_${dev.ip.replaceAll('.', '_')}.png");
        final result = await adb.takeScreenshot(dev.ip, path);
        if (result != null && mounted) {
          setState(() {
            _thumbnails[dev.ip] = result;
          });
        }
      },
    ));
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _isLoading = true);
    final list = await DeviceStorage.load();
    if (mounted) {
      setState(() {
        saved = list;
      });
    }
    final results = await adb.checkAll(list.map((d) => d.ip).toList());
    if (mounted) {
      setState(() {
        saved = list;
        statuses = {for (final s in results) s.ip: s};
        _isLoading = false;
      });
      _captureAll();
    }
  }

  Future<void> _registerViaUsb() async {
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
      final ip = await adb.registerViaUsb(id);
      if (!mounted) return;
      if (ip != null) {
        final nextIndex = (await DeviceStorage.load()).length + 1;
        await DeviceStorage.add(ip, name: "Планшет $nextIndex");
        if (!mounted) return;
        added++;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Планшет $ip зарегистрирован и сохранён"),
          backgroundColor: Colors.green.shade700,
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

  Future<void> _wakeScreen(SavedDevice dev) async {
    AppLogger.log("Включение экрана на ${dev.ip}");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("${dev.name}: включаю экран..."),
        duration: const Duration(seconds: 2),
      ));
    }
    await adb.wakeUp(dev.ip);
  }

  Future<void> _sleepScreen(SavedDevice dev) async {
    AppLogger.log("Выключение экрана на ${dev.ip}");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("${dev.name}: выключаю экран..."),
        duration: const Duration(seconds: 2),
      ));
    }
    await adb.sleep(dev.ip);
  }

  Future<void> _showDeviceControls(SavedDevice dev) async {
    final vol = await adb.getVolume(dev.ip);
    final bright = await adb.getBrightness(dev.ip);
    final volMax = await adb.getVolumeMax(dev.ip);
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
                          value: currentVol.toDouble().clamp(0, maxVol.toDouble()),
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

  Future<void> _syncAndPlay(SavedDevice dev) async {
    if (!mounted) return;
    final progress = ValueNotifier<String>("Подключение...");
    bool cancelled = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => ValueListenableBuilder<String>(
        valueListenable: progress,
        builder: (_, msg, __) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: Text(dev.name, style: const TextStyle(fontSize: 16)),
          content: Row(
            children: [
              const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.blue)),
              const SizedBox(width: 16),
              Expanded(child: Text(msg, style: const TextStyle(fontSize: 13))),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.of(c).pop();
              },
              child: const Text("Отмена"),
            ),
          ],
        ),
      ),
    );
    final mediaDir = await MediaConfig.resolveDir();
    final norm =
        await Transcoder.normalizeDir(mediaDir, onProgress: (file, i, total) {
      progress.value = "Конвертация ($i/$total): $file";
    });
    if (cancelled) {
      progress.dispose();
      return;
    }
    final result = await adb.syncDeviceDirect(
      dev.ip,
      mediaDir,
      tryHttpFirst: statuses[dev.ip]?.httpAvailable ?? true,
      isCancelled: () => cancelled,
      onProgress: (done, total, file) {
        if (file.isNotEmpty) progress.value = "($done/$total) $file";
      },
    );
    if (cancelled) {
      progress.dispose();
      return;
    }
    if (!result.success) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            "${dev.name}: ${result.error ?? 'синхронизация не выполнена'}"),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
      ));
      if (norm.ffmpegMissing) await _showFfmpegMissingDialog();
      return;
    }
    final canLaunch = statuses[dev.ip]?.online ?? false;
    if (canLaunch) {
      await adb.wakeUp(dev.ip, launchPlayer: true);
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    if (!mounted) return;
    final launchText = canLaunch ? ", запущено" : ", устройство офлайн";
    final fallbackText = result.usedFallback ? " через fallback" : "";
    final summary = result.pushed.isEmpty
        ? "Все файлы актуальны$launchText"
        : "Загружено ${result.pushed.length}$fallbackText: ${result.pushed.join(', ')}";
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("${dev.name}: $summary"),
      backgroundColor: Colors.green.shade700,
      duration: const Duration(seconds: 6),
    ));
    if (norm.ffmpegMissing) await _showFfmpegMissingDialog();
  }

  Future<void> _syncAndPlayAll() => _syncAll(launch: true);

  /// Запуск на всех с приглушённым звуком БЕЗ синхронизации файлов:
  /// просто будит и перезапускает плеер, затем ставит громкость 0.
  Future<void> _syncAndPlayAllMuted() =>
      _syncAll(launch: true, mute: true, sync: false);

  /// Тихая синхронизация всех онлайн-устройств БЕЗ запуска/перезапуска плеера.
  Future<void> _syncOnlyAll() => _syncAll(launch: false);

  /// Прогон по всем онлайн-устройствам последовательно с прогрессом и отменой.
  /// [sync] — сверять/докачивать файлы (иначе только запуск);
  /// [launch] — после этого перезапустить плеер;
  /// [mute] — сразу после запуска поставить громкость 0.
  Future<void> _syncAll(
      {required bool launch, bool mute = false, bool sync = true}) async {
    final online = saved.where((d) => statuses[d.ip]?.online == true).toList();
    if (online.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Нет онлайн-устройств"),
        backgroundColor: Colors.orange,
      ));
      return;
    }
    final mediaDir = await MediaConfig.resolveDir();
    if (!mounted) return;

    final progress = ValueNotifier<_BulkSyncProgress>(
      _BulkSyncProgress(
        currentIndex: 0,
        totalDevices: online.length,
        currentDevice: "Подготовка...",
        currentStep: sync ? "Проверяю медиатеку" : "Запуск плеера",
        deviceStates: {for (final dev in online) dev.name: "В очереди"},
      ),
    );
    bool cancelled = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => ValueListenableBuilder<_BulkSyncProgress>(
        valueListenable: progress,
        builder: (_, state, __) {
          final value = state.totalDevices == 0
              ? null
              : state.currentIndex / state.totalDevices;
          return AlertDialog(
            backgroundColor: const Color(0xFF2C2C2E),
            title: Text(
                launch
                    ? (mute ? "Запуск всех (без звука)" : "Запуск всех планшетов")
                    : "Синхронизация (без запуска)",
                style: const TextStyle(fontSize: 17)),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: value,
                    backgroundColor: Colors.white12,
                    color: Colors.blue,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    "${state.currentIndex}/${state.totalDevices}: ${state.currentDevice}",
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(state.currentStep,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white60)),
                  const SizedBox(height: 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: SingleChildScrollView(
                      child: Column(
                        children: state.deviceStates.entries.map((entry) {
                          final active = entry.key == state.currentDevice;
                          final done = entry.value.startsWith("Готово") ||
                              entry.value == "Актуально" ||
                              entry.value == "Запущено";
                          final error = entry.value.startsWith("Ошибка");
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Icon(
                                  error
                                      ? Icons.error_outline_rounded
                                      : done
                                          ? Icons.check_circle_outline_rounded
                                          : active
                                              ? Icons.sync_rounded
                                              : Icons.schedule_rounded,
                                  size: 16,
                                  color: error
                                      ? Colors.redAccent
                                      : done
                                          ? Colors.greenAccent
                                          : active
                                              ? Colors.blue
                                              : Colors.white24,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(entry.key,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12)),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(entry.value,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                          fontSize: 11, color: Colors.white54)),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => cancelled = true,
                child: const Text("Остановить после текущего"),
              ),
            ],
          );
        },
      ),
    );

    // Конвертация не-mp4 → mp4 один раз для общей медиа-папки (только при синке).
    final norm = sync
        ? await Transcoder.normalizeDir(mediaDir, onProgress: (file, i, total) {
            progress.value = progress.value.copyWith(
              currentDevice: "Подготовка...",
              currentStep: "Конвертация ($i/$total): $file",
            );
          })
        : null;

    final Map<String, SyncResult> results = {};
    for (int i = 0; i < online.length; i++) {
      if (cancelled) break;
      final dev = online[i];
      if (!mounted) return;
      final deviceOnline = statuses[dev.ip]?.online ?? false;

      SyncResult result;
      if (sync) {
        progress.value = progress.value.updateDevice(
          dev.name,
          "Подключение",
          currentIndex: i + 1,
          currentDevice: dev.name,
          currentStep: "Подключение к ${dev.ip}",
        );
        result = await adb.syncDeviceDirect(
          dev.ip,
          mediaDir,
          tryHttpFirst: statuses[dev.ip]?.httpAvailable ?? true,
          isCancelled: () => cancelled,
          onProgress: (done, total, file) {
            if (file.isEmpty) return;
            progress.value = progress.value.updateDevice(
              dev.name,
              "($done/$total) $file",
              currentStep: "Файл $done из $total: $file",
            );
          },
        );
      } else {
        // Без синхронизации: только запуск, файлы не трогаем.
        progress.value = progress.value.updateDevice(
          dev.name,
          "Запуск",
          currentIndex: i + 1,
          currentDevice: dev.name,
          currentStep: "Запуск плеера на ${dev.ip}",
        );
        result = const SyncResult(success: true, pushed: [], transport: 'launch');
      }

      if (launch && result.success && deviceOnline) {
        progress.value = progress.value.updateDevice(
          dev.name,
          mute ? "Запуск (без звука)" : "Запуск",
          currentStep: mute
              ? "Запускаю плеер без звука на ${dev.name}"
              : "Запускаю плеер на ${dev.name}",
        );
        await adb.wakeUp(dev.ip, launchPlayer: true);
        if (mute) await adb.setVolume(dev.ip, 0);
      }
      results[dev.name] = result;
      progress.value = progress.value.updateDevice(
        dev.name,
        !result.success
            ? "Ошибка"
            : !sync
                ? "Запущено"
                : (result.pushed.isEmpty
                    ? "Актуально"
                    : "Готово: ${result.pushed.length}"),
        currentStep: !result.success
            ? "${dev.name}: ${result.error ?? 'ошибка'}"
            : !sync
                ? "${dev.name}: запущено"
                : "${dev.name}: синхронизация завершена",
      );
    }

    // Отмена закрывает диалог и прекращает без сводки.
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    if (!mounted || cancelled) return;
    final lines = results.entries.map((e) {
      final r = e.value;
      if (!r.success) {
        return "${e.key}: ошибка — ${r.error ?? 'не выполнено'}";
      }
      if (!sync) return "${e.key}: запущено";
      final transport =
          r.usedFallback ? '${r.transport}, fallback' : r.transport;
      return r.pushed.isEmpty
          ? "${e.key}: актуально ($transport)"
          : "${e.key}: ${r.pushed.length} файлов ($transport)";
    }).join('\n');
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: Text(!sync
            ? "Запуск завершён"
            : "Синхронизация завершена"),
        content: Text(
            lines.isEmpty
                ? "Ни один планшет не был обработан"
                : lines,
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text("OK"))
        ],
      ),
    );
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
          "Найдены ролики .mov/.mkv/.avi/.webm, которые могут не играть на "
          "планшете (звук идёт, видео нет). Для автоконвертации в MP4 "
          "установите ffmpeg:\n\n"
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

  Future<void> _syncOnly(SavedDevice dev) async {
    if (!mounted) return;
    final progress = ValueNotifier<String>("Подключение...");
    bool cancelled = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => ValueListenableBuilder<String>(
        valueListenable: progress,
        builder: (_, msg, __) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: Text(dev.name, style: const TextStyle(fontSize: 16)),
          content: Row(
            children: [
              const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.blue)),
              const SizedBox(width: 16),
              Expanded(child: Text(msg, style: const TextStyle(fontSize: 13))),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.of(c).pop();
              },
              child: const Text("Отмена"),
            ),
          ],
        ),
      ),
    );
    final mediaDir = await MediaConfig.resolveDir();
    final norm =
        await Transcoder.normalizeDir(mediaDir, onProgress: (file, i, total) {
      progress.value = "Конвертация ($i/$total): $file";
    });
    if (cancelled) {
      progress.dispose();
      return;
    }
    final result = await adb.syncDeviceDirect(
      dev.ip,
      mediaDir,
      tryHttpFirst: statuses[dev.ip]?.httpAvailable ?? true,
      isCancelled: () => cancelled,
      onProgress: (done, total, file) {
        if (file.isNotEmpty) progress.value = "($done/$total) $file";
      },
    );
    if (cancelled) {
      progress.dispose();
      return;
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    if (!mounted) return;
    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            "${dev.name}: ${result.error ?? 'синхронизация не выполнена'}"),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
      ));
      if (norm.ffmpegMissing) await _showFfmpegMissingDialog();
      return;
    }
    final summary = result.pushed.isEmpty
        ? "Все файлы актуальны"
        : "Загружено ${result.pushed.length}: ${result.pushed.join(', ')}";
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("${dev.name}: $summary"),
      backgroundColor: Colors.green.shade700,
      duration: const Duration(seconds: 6),
    ));
    if (norm.ffmpegMissing) await _showFfmpegMissingDialog();
  }

  /// Запуск плеера на одном планшете БЕЗ синхронизации файлов, со звуком 0.
  /// Аналог массового «Без звука», но для конкретного устройства.
  Future<void> _launchMuted(SavedDevice dev) async {
    if (!mounted) return;
    final online = statuses[dev.ip]?.online ?? false;
    if (!online) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("${dev.name}: устройство офлайн"),
        backgroundColor: Colors.red.shade700,
      ));
      return;
    }
    await adb.wakeUp(dev.ip, launchPlayer: true);
    await adb.setVolume(dev.ip, 0);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("${dev.name}: запущено без звука (без синхронизации)"),
      backgroundColor: Colors.green.shade700,
      duration: const Duration(seconds: 4),
    ));
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
      await adb.bulkSleep(saved.map((d) => d.ip).toList());
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final onlineCount = statuses.values.where((s) => s.online).length;

    return Padding(
      padding: const EdgeInsets.all(40.0),
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
                  const Text("Устройства",
                      style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1)),
                  Text("$onlineCount из ${saved.length} в сети",
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 14)),
                ],
              ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: (_isRegistering || _busy) ? null : _registerViaUsb,
                    icon: _isRegistering
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                color: Colors.greenAccent, strokeWidth: 2))
                        : const Icon(Icons.usb_rounded),
                    label: const Text("USB"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.greenAccent,
                      side: const BorderSide(color: Colors.greenAccent),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: (saved.isEmpty || _busy)
                        ? null
                        : () => _guard(_syncOnlyAll),
                    icon: const Icon(Icons.sync_rounded),
                    label: const Text("Синхронизировать"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: (saved.isEmpty || _busy)
                        ? null
                        : () => _guard(_syncAndPlayAll),
                    icon: const Icon(Icons.cast_connected_rounded),
                    label: const Text("Запустить все"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blue,
                      side: const BorderSide(color: Colors.blue),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: (saved.isEmpty || _busy)
                        ? null
                        : () => _guard(_syncAndPlayAllMuted),
                    icon: const Icon(Icons.volume_off_rounded),
                    label: const Text("Без звука"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.lightBlueAccent,
                      side: const BorderSide(color: Colors.lightBlueAccent),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
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
                  ElevatedButton.icon(
                    onPressed: (_isLoading || _busy) ? null : _refresh,
                    icon: _isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.refresh_rounded),
                    label: const Text("Обновить"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
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
          const SizedBox(height: 40),
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

  Widget _emptyState() {
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
          const Text("Подключите планшет через USB и нажмите «Добавить по USB»",
              style: TextStyle(color: Colors.white24, fontSize: 13)),
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

    return _HoverBuilder(
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        transform: hovered
            ? Matrix4.translationValues(0, -3, 0)
            : Matrix4.identity(),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: hovered ? 0.07 : 0.05),
          borderRadius: BorderRadius.circular(24),
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
        padding: const EdgeInsets.all(20),
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
                        color: isOnline ? Colors.greenAccent : Colors.white24,
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
                  Text(isOnline ? status?.transport ?? "Online" : "Offline",
                      style: TextStyle(
                          fontSize: 11,
                          color:
                              isOnline ? Colors.greenAccent : Colors.white38)),
                ],
              ),
              if (isOnline)
                Row(
                  children: [
                    Icon(
                        bat < 20
                            ? Icons.battery_alert_rounded
                            : Icons.battery_charging_full_rounded,
                        size: 14,
                        color: bat < 20 ? Colors.redAccent : Colors.white24),
                    const SizedBox(width: 4),
                    Text("${status?.battery ?? "??"}%",
                        style: TextStyle(
                            fontSize: 12,
                            color: bat < 20 ? Colors.redAccent : Colors.white24,
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
                // Превью проявляется плавно при обновлении скриншота.
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  switchInCurve: Curves.easeOut,
                  child: _thumbnails.containsKey(dev.ip)
                      ? Image.file(File(_thumbnails[dev.ip]!),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
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
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(dev.name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
          Text(dev.ip,
              style: const TextStyle(fontSize: 11, color: Colors.white38)),
          const SizedBox(height: 12),
          Row(
            children: [
              _smallAppleBtn(Icons.play_arrow_rounded,
                  (isOnline && !_busy) ? () => _guard(() => _syncAndPlay(dev)) : null,
                  tooltip: "Синхронизировать плейлист и запустить"),
              const SizedBox(width: 8),
              _smallAppleBtn(Icons.sync_rounded,
                  (isOnline && !_busy) ? () => _guard(() => _syncOnly(dev)) : null,
                  tooltip: "Только синхронизация (без перезапуска)"),
              const SizedBox(width: 8),
              _smallAppleBtn(Icons.volume_off_rounded,
                  (isOnline && !_busy) ? () => _guard(() => _launchMuted(dev)) : null,
                  tooltip: "Запустить без звука (без синхронизации)"),
              const SizedBox(width: 8),
              _smallAppleBtn(Icons.tune_rounded,
                  canControl ? () => _showDeviceControls(dev) : null,
                  tooltip: "Громкость и яркость"),
              const SizedBox(width: 8),
              _smallAppleBtn(Icons.wb_sunny_rounded,
                  canControl ? () => _wakeScreen(dev) : null,
                  tooltip: "Включить экран"),
              const SizedBox(width: 8),
              _smallAppleBtn(Icons.power_settings_new_rounded,
                  canControl ? () => _sleepScreen(dev) : null,
                  tooltip: "Выключить экран"),
            ],
          )
        ],
      ),
    ));
  }

  Widget _smallAppleBtn(IconData icon, VoidCallback? onTap, {String? tooltip}) {
    final enabled = onTap != null;
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
                      : Colors.white70),
        ),
      ),
    );
    // MouseRegion-курсор внутри _HoverBuilder работает только для активной
    // кнопки; для выключенной оставляем обычный курсор.
    final wrapped = enabled
        ? btn
        : MouseRegion(cursor: SystemMouseCursors.basic, child: btn);
    return tooltip != null ? Tooltip(message: tooltip, child: wrapped) : wrapped;
  }
}

class MediaScreen extends StatefulWidget {
  const MediaScreen({super.key});
  @override
  State<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends State<MediaScreen> {
  List<File> videos = [];
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
    final disk = _videoDir.listSync().whereType<File>().where((f) {
      final name = p.basename(f.path);
      final lower = name.toLowerCase();
      if (lower.startsWith('.')) return false;
      if (lower == _playlistFileName) return false;
      // Не показываем исходник, если он уже сконвертирован в mp4.
      if (Transcoder.hasMp4Twin(_videoDir.path, name)) return false;
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

    if (mounted) setState(() => videos = ordered);
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
            "ffmpeg не найден — .mov/.mkv/.avi не сконвертированы и могут не "
            "играть на планшете. Установите: brew install ffmpeg"),
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
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return "ролика";
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
    final totalMb =
        videos.fold<int>(0, (s, f) => s + f.lengthSync()) / (1024 * 1024);

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
            padding: const EdgeInsets.all(40.0),
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
                        const Text("Плейлист",
                            style: TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -1)),
                        Text(
                            "${videos.length} роликов • ${totalMb.toStringAsFixed(1)} MB",
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 14)),
                      ],
                    ),
                    Wrap(
                      spacing: 12,
                      children: [
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
                          label: const Text("Добавить"),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
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
                  color: Colors.blue.withValues(alpha: 0.15),
                  border: Border.all(
                      color: Colors.blue, width: 3, style: BorderStyle.solid),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.file_download_rounded,
                          size: 100, color: Colors.blue),
                      SizedBox(height: 20),
                      Text("Отпусти чтобы добавить видео",
                          style: TextStyle(
                              color: Colors.blue,
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline, color: Colors.blue.shade200, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "Перетащи видео из Finder сюда • Меняй порядок drag&drop • Галочка = выбрать для удаления",
              style: TextStyle(color: Colors.blue.shade200, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// Панель массовых действий: появляется, когда отмечен хотя бы один ролик.
  Widget _selectionBar() {
    final allSelected =
        videos.isNotEmpty && _selected.length == videos.length;
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
            value: allSelected
                ? true
                : (_selected.isEmpty ? false : null),
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
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600)),
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
    final sizeMb = (file.lengthSync() / (1024 * 1024)).toStringAsFixed(1);
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
    super.dispose();
  }

  void _startPairing() {
    const seconds = 30;
    globalServer?.startPairing(duration: const Duration(seconds: seconds));
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
    globalServer?.stopPairing();
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
      });
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('autoOffTime', _timeController.text);
    await prefs.setBool('autoOffEnabled', autoOffEnabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text("Настройки сохранены")));
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
                    onChanged: (v) => setState(() => autoOffEnabled = v))),
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
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _saveSettings,
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                child: const Text("Сохранить",
                    style: TextStyle(fontWeight: FontWeight.bold)),
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
