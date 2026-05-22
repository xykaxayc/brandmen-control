import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

class AppLogger {
  static File? _logFile;

  static Future<void> init() async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      await supportDir.create(recursive: true);
      _logFile = File(p.join(supportDir.path, 'brandmen.log'));
      await _checkCleanup();
      await log("--- ЗАПУСК ПРИЛОЖЕНИЯ ---");
    } catch (e) {
      print("Не удалось инициализировать логгер: $e");
    }
  }

  static Future<void> log(String message) async {
    final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    final entry = "[$timestamp] $message\n";
    print(entry.trim());
    final f = _logFile;
    if (f == null) return;
    try {
      await f.writeAsString(entry, mode: FileMode.append);
    } catch (e) {
      print("Ошибка записи лога: $e");
    }
  }

  static String? get logPath => _logFile?.path;

  static Future<void> _checkCleanup() async {
    final f = _logFile;
    if (f == null) return;
    if (await f.exists()) {
      final lastModified = await f.lastModified();
      final diff = DateTime.now().difference(lastModified).inDays;
      if (diff >= 7) {
        await f.delete();
      }
    }
  }
}
