import 'dart:io';
import 'package:path/path.dart' as p;
import 'logger.dart';

class AutoStart {
  static const _label = 'com.brandmen.control';

  static Future<bool> isEnabled() async {
    if (Platform.isMacOS) {
      final file = File(_macPlistPath());
      return file.existsSync();
    } else if (Platform.isWindows) {
      final res = await Process.run('reg', [
        'query',
        'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run',
        '/v', 'BrandmenControl'
      ]);
      return res.exitCode == 0;
    }
    return false;
  }

  static Future<bool> enable() async {
    try {
      if (Platform.isMacOS) {
        return _macEnable();
      } else if (Platform.isWindows) {
        return _winEnable();
      }
    } catch (e) {
      AppLogger.log("Autostart enable error: $e");
    }
    return false;
  }

  static Future<bool> disable() async {
    try {
      if (Platform.isMacOS) {
        return _macDisable();
      } else if (Platform.isWindows) {
        return _winDisable();
      }
    } catch (e) {
      AppLogger.log("Autostart disable error: $e");
    }
    return false;
  }

  // ========== macOS (LaunchAgent) ==========
  static String _macPlistPath() {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/Library/LaunchAgents/$_label.plist';
  }

  static Future<bool> _macEnable() async {
    final exePath = Platform.resolvedExecutable;
    final plistPath = _macPlistPath();
    await Directory(p.dirname(plistPath)).create(recursive: true);

    final plist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$exePath</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
''';
    await File(plistPath).writeAsString(plist);
    await Process.run('launchctl', ['load', '-w', plistPath]);
    AppLogger.log("Автозапуск macOS включён: $plistPath");
    return true;
  }

  static Future<bool> _macDisable() async {
    final plistPath = _macPlistPath();
    final file = File(plistPath);
    if (await file.exists()) {
      await Process.run('launchctl', ['unload', '-w', plistPath]);
      await file.delete();
      AppLogger.log("Автозапуск macOS отключён");
    }
    return true;
  }

  // ========== Windows (Registry) ==========
  static Future<bool> _winEnable() async {
    final exePath = Platform.resolvedExecutable;
    final res = await Process.run('reg', [
      'add',
      'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run',
      '/v', 'BrandmenControl',
      '/t', 'REG_SZ',
      '/d', exePath,
      '/f',
    ]);
    AppLogger.log("Автозапуск Windows: exitCode=${res.exitCode}");
    return res.exitCode == 0;
  }

  static Future<bool> _winDisable() async {
    final res = await Process.run('reg', [
      'delete',
      'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run',
      '/v', 'BrandmenControl',
      '/f',
    ]);
    return res.exitCode == 0;
  }
}
