import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MediaConfig {
  static const _key = 'custom_media_dir';
  static String? _current;

  static Future<String> resolveDir() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null && Directory(saved).existsSync()) {
      _current = saved;
      return saved;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final defaultPath = p.join(appDir.path, 'BrandmenVideos');
    await Directory(defaultPath).create(recursive: true);
    _current = defaultPath;
    return defaultPath;
  }

  static String? get current => _current;

  static Future<void> setCustom(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, path);
    }
    await resolveDir();
  }
}
