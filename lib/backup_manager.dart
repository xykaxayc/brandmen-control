import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'device_storage.dart';
import 'media_config.dart';
import 'logger.dart';

class BackupManager {
  static const _version = 1;

  static Future<String?> export() async {
    final prefs = await SharedPreferences.getInstance();
    final devices = await DeviceStorage.load();

    final data = {
      'version': _version,
      'exported_at': DateTime.now().toIso8601String(),
      'devices': devices.map((d) => d.toJson()).toList(),
      'auto_off_enabled': prefs.getBool('autoOffEnabled') ?? false,
      'auto_off_time': prefs.getString('autoOffTime') ?? '22:00',
      'custom_media_dir': prefs.getString('custom_media_dir'),
      'auto_start': prefs.getBool('autoStart') ?? false,
    };
    final json = const JsonEncoder.withIndent('  ').convert(data);

    final fileName = 'brandmen-backup-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.json';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Сохранить бэкап настроек',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path != null) {
      try {
        await File(path).writeAsString(json);
        AppLogger.log("Бэкап сохранён: $path");
      } catch (e) {
        AppLogger.log("Бэкап: ошибка записи $e");
      }
    }
    return path;
  }

  /// Возвращает количество восстановленных устройств или null при отмене/ошибке
  static Future<int?> import() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Выбрать файл бэкапа',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null) return null;

    try {
      final content = await File(path).readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      final devicesJson = (data['devices'] as List?) ?? const [];
      final devices = devicesJson
          .map((e) => SavedDevice.fromJson(e as Map<String, dynamic>))
          .toList();
      await DeviceStorage.save(devices);

      final prefs = await SharedPreferences.getInstance();
      if (data['auto_off_enabled'] is bool) {
        await prefs.setBool('autoOffEnabled', data['auto_off_enabled'] as bool);
      }
      if (data['auto_off_time'] is String) {
        await prefs.setString('autoOffTime', data['auto_off_time'] as String);
      }
      if (data['custom_media_dir'] is String) {
        await MediaConfig.setCustom(data['custom_media_dir'] as String);
      } else if (data['custom_media_dir'] == null) {
        await MediaConfig.setCustom(null);
      }
      if (data['auto_start'] is bool) {
        await prefs.setBool('autoStart', data['auto_start'] as bool);
      }

      AppLogger.log("Бэкап восстановлен: ${devices.length} устройств");
      return devices.length;
    } catch (e) {
      AppLogger.log("Ошибка импорта бэкапа: $e");
      return null;
    }
  }
}
