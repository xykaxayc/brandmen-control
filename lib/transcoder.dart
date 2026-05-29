import 'dart:io';
import 'package:path/path.dart' as p;
import 'logger.dart';

/// Результат нормализации медиа-папки.
class NormalizeResult {
  final bool ffmpegMissing;
  final List<String> converted; // имена созданных mp4
  final List<String> failed; // имена исходников, которые не удалось сконвертировать
  const NormalizeResult({
    this.ffmpegMissing = false,
    this.converted = const [],
    this.failed = const [],
  });

  bool get didWork => converted.isNotEmpty || failed.isNotEmpty;
}

/// Конвертация видео в универсальный MP4 (H.264 + AAC) через системный ffmpeg.
///
/// Android `VideoView` декодирует не все кодеки внутри .mov/.mkv/.avi/.webm
/// (частая жалоба: «звук есть, видео нет»). Чтобы ролики гарантированно
/// игрались на любом планшете, перекодируем их в mp4 H.264 на ПК до отправки.
class Transcoder {
  Transcoder._();

  static String? _cachedFfmpeg;
  static bool _searched = false;

  /// Расширения, которые надёжно НЕ играют на части Android-устройств.
  /// (.mp4 сюда не входит — он уже целевой формат.)
  static const Set<String> convertExts = {'.mov', '.mkv', '.avi', '.webm'};

  /// Ищет бинарник ffmpeg: в PATH и типичных местах установки.
  /// Возвращает путь или null, если ffmpeg не установлен.
  static Future<String?> findFfmpeg() async {
    if (_searched) return _cachedFfmpeg;
    _searched = true;
    final candidates = <String>[
      'ffmpeg', // PATH
      '/opt/homebrew/bin/ffmpeg', // Apple Silicon brew
      '/usr/local/bin/ffmpeg', // Intel brew
      '/usr/bin/ffmpeg',
      r'C:\ffmpeg\bin\ffmpeg.exe',
      r'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
    ];
    for (final c in candidates) {
      try {
        final r = await Process.run(c, ['-version']);
        if (r.exitCode == 0) {
          _cachedFfmpeg = c;
          AppLogger.log('ffmpeg найден: $c');
          return c;
        }
      } catch (_) {
        // не найден по этому пути — пробуем следующий
      }
    }
    AppLogger.log('ffmpeg не найден ни в PATH, ни в типичных местах');
    _cachedFfmpeg = null;
    return null;
  }

  /// Сбрасывает кэш поиска ffmpeg (если пользователь его доустановил).
  static void resetFfmpegCache() {
    _searched = false;
    _cachedFfmpeg = null;
  }

  static bool _isConvertible(String name) =>
      convertExts.contains(p.extension(name).toLowerCase());

  /// Есть ли рядом с не-mp4 файлом готовый mp4-двойник (результат конвертации).
  /// Используется, чтобы не показывать/не отправлять исходник дважды.
  static bool hasMp4Twin(String dir, String fileName) {
    if (!_isConvertible(fileName)) return false;
    final base = p.basenameWithoutExtension(fileName);
    return File(p.join(dir, '$base.mp4')).existsSync();
  }

  /// Конвертирует все не-mp4 видео в папке в `<имя>.mp4` (рядом, оригинал не
  /// удаляется). Уже сконвертированные пропускаются (кэш по времени изменения).
  /// После конвертации переписывает playlist.m3u: не-mp4 имена → mp4.
  static Future<NormalizeResult> normalizeDir(
    String dir, {
    void Function(String file, int index, int total)? onProgress,
  }) async {
    final folder = Directory(dir);
    if (!await folder.exists()) return const NormalizeResult();

    final toConvert = folder.listSync().whereType<File>().where((f) {
      final name = p.basename(f.path);
      if (name.startsWith('.')) return false;
      return _isConvertible(name);
    }).toList();

    if (toConvert.isEmpty) return const NormalizeResult();

    // Нужно ли вообще что-то делать (нет ли свежих mp4 для всех)?
    final pending = toConvert.where((f) {
      final base = p.basenameWithoutExtension(f.path);
      final out = File(p.join(dir, '$base.mp4'));
      if (!out.existsSync()) return true;
      return !out.statSync().modified.isAfter(f.statSync().modified) &&
          !out.statSync().modified.isAtSameMomentAs(f.statSync().modified);
    }).toList();

    if (pending.isEmpty) {
      // Всё уже сконвертировано — просто убеждаемся, что плейлист на mp4.
      await _rewritePlaylist(dir);
      return const NormalizeResult();
    }

    final ffmpeg = await findFfmpeg();
    if (ffmpeg == null) {
      return const NormalizeResult(ffmpegMissing: true);
    }

    final converted = <String>[];
    final failed = <String>[];
    for (int i = 0; i < pending.length; i++) {
      final src = pending[i];
      final base = p.basenameWithoutExtension(src.path);
      final outPath = p.join(dir, '$base.mp4');
      final tmp = File('$outPath.tmp');

      onProgress?.call(p.basename(src.path), i, pending.length);

      if (await tmp.exists()) await tmp.delete();

      AppLogger.log('ffmpeg: конвертирую ${p.basename(src.path)} → $base.mp4');
      final r = await Process.run(ffmpeg, [
        '-y',
        '-i', src.path,
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-crf', '23',
        '-pix_fmt', 'yuv420p', // важно для совместимости с Android-декодерами
        // гарантируем чётные размеры (требование H.264)
        '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2',
        '-c:a', 'aac',
        '-b:a', '128k',
        '-movflags', '+faststart',
        tmp.path,
      ]);

      if (r.exitCode == 0 && await tmp.exists()) {
        final out = File(outPath);
        if (await out.exists()) await out.delete();
        await tmp.rename(outPath);
        converted.add('$base.mp4');
        AppLogger.log('ffmpeg: готово $base.mp4');
      } else {
        failed.add(p.basename(src.path));
        if (await tmp.exists()) await tmp.delete();
        AppLogger.log(
            'ffmpeg: ошибка ${p.basename(src.path)} (код ${r.exitCode}): ${r.stderr}');
      }
    }

    await _rewritePlaylist(dir);
    return NormalizeResult(converted: converted, failed: failed);
  }

  /// Переписывает playlist.m3u: строки с не-mp4 именами заменяет на mp4-двойник,
  /// если он есть в папке.
  static Future<void> _rewritePlaylist(String dir) async {
    final pl = File(p.join(dir, 'playlist.m3u'));
    if (!await pl.exists()) return;
    final lines = await pl.readAsLines();
    var changed = false;
    final out = <String>[];
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) {
        out.add(line);
        continue;
      }
      if (_isConvertible(t)) {
        final base = p.basenameWithoutExtension(t);
        final mp4 = '$base.mp4';
        if (await File(p.join(dir, mp4)).exists()) {
          out.add(mp4);
          changed = true;
          continue;
        }
      }
      out.add(line);
    }
    if (changed) {
      await pl.writeAsString('${out.join('\n')}\n');
      AppLogger.log('playlist.m3u обновлён: не-mp4 → mp4');
    }
  }
}
