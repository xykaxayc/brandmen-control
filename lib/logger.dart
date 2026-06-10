import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

class AppLogger {
  static File? _logFile;
  // Открытый на всё время работы sink: запись строки — это append в буфер,
  // а не open/write/close файла на каждую строку (как было с writeAsString).
  static IOSink? _logSink;

  // Кольцевой буфер последних строк лога в памяти — для вкладки «Логи»
  // (сервисный режим), которая показывает поток событий прямо в приложении.
  static const int _maxBuffer = 2000;
  static final List<String> _lines = <String>[];

  // Очередь ещё не отправленных строк для живого потока на сервер (раз в ~3 с
  // фоновый стример забирает их и шлёт на {URL}/live). Ограничена, чтобы не
  // расти бесконечно, если сервер недоступен.
  static const int _maxPending = 5000;
  static final List<String> _pending = <String>[];

  /// Забрать и очистить накопленные строки для отправки в живой поток.
  static List<String> drainPending() {
    if (_pending.isEmpty) return const [];
    final out = List<String>.from(_pending);
    _pending.clear();
    return out;
  }

  /// Вернуть строки в очередь (если отправка не удалась), не превышая лимит.
  static void requeuePending(List<String> lines) {
    _pending.insertAll(0, lines);
    if (_pending.length > _maxPending) {
      _pending.removeRange(0, _pending.length - _maxPending);
    }
  }

  /// Растёт при новых строках — UI слушает и обновляется. Уведомления
  /// троттлятся (~300 мс): во время синка лог сыпется десятками строк в
  /// секунду, и rebuild вкладки «Логи» на каждую строку тормозил весь UI.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static Timer? _revisionTimer;

  static void _bumpRevision() {
    if (_revisionTimer != null) return;
    _revisionTimer = Timer(const Duration(milliseconds: 300), () {
      _revisionTimer = null;
      revision.value++;
    });
  }

  /// Строки лога в памяти (от старых к новым). View без копирования —
  /// геттер дёргается на каждый rebuild вкладки «Логи».
  static List<String> get lines => UnmodifiableListView(_lines);

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
      _logSink = _logFile!.openWrite(mode: FileMode.append);
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
    // В очередь живого потока.
    _pending.add(entry.trimRight());
    if (_pending.length > _maxPending) {
      _pending.removeRange(0, _pending.length - _maxPending);
    }
    _bumpRevision();

    try {
      _logSink?.write(entry);
    } catch (e) {
      stderr.writeln("Ошибка записи лога: $e");
    }
  }

  static String? get logPath => _logFile?.path;

  /// Дожидается записи буфера sink на диск — вызывать перед чтением файла
  /// лога (отправка полного лога на сервер).
  static Future<void> flush() async {
    try {
      await _logSink?.flush();
    } catch (_) {}
  }

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
