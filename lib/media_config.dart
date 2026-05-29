import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Единый список видеоформатов, поддерживаемых системой end-to-end
/// (показ в UI, синхронизация, авто-конвертация). НЕ дублировать списки по
/// файлам — иначе формат, играющий в одном месте, молча отсеивается в другом.
/// .wmv/.flv намеренно отсутствуют: они не конвертируются и не отправляются.
const List<String> kVideoExtensions = ['.mp4', '.mkv', '.mov', '.avi', '.webm'];

/// true, если путь/имя файла — поддерживаемое видео.
bool isVideoFile(String pathOrName) =>
    kVideoExtensions.contains(p.extension(pathOrName).toLowerCase());

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
