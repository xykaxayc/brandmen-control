import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

class AppLogger {
  static File? _logFile;

  // Кольцевой буфер последних строк лога в памяти — для вкладки «Логи»
  // (сервисный режим), которая показывает поток событий прямо в приложении.
  static const int _maxBuffer = 2000;
  static final List<String> _lines = <String>[];

  /// Растёт при каждой новой строке — UI слушает и обновляется.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Снимок строк лога в памяти (от старых к новым).
  static List<String> get lines => List.unmodifiable(_lines);

  /// Очищает буфер в памяти (только во вкладке; файл не трогает).
  static void clearBuffer() {
    _lines.clear();
    revision.value++;
  }

  static Future<void> init() async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      await supportDir.create(recursive: true);
      _logFile = File(p.join(supportDir.path, 'brandmen.log'));
      await _checkCleanup();
      await log("--- ЗАПУСК ПРИЛОЖЕНИЯ ---");
    } catch (e) {
      stderr.writeln("Не удалось инициализировать логгер: $e");
    }
  }

  static Future<void> log(String message) async {
    final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    final entry = "[$timestamp] $message\n";
    stdout.writeln(entry.trim());

    // В память — для вкладки «Логи».
    _lines.add(entry.trimRight());
    if (_lines.length > _maxBuffer) {
      _lines.removeRange(0, _lines.length - _maxBuffer);
    }
    revision.value++;

    final f = _logFile;
    if (f == null) return;
    try {
      await f.writeAsString(entry, mode: FileMode.append);
    } catch (e) {
      stderr.writeln("Ошибка записи лога: $e");
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
