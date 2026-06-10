import 'dart:io';
import 'dart:convert';
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

  static const _conversionProfileVersion = 2;
  static const _profileMarkerPrefix = '# Brandmen conversion profile ';

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
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      p.join(exeDir, 'ffmpeg', Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg'),
      p.join(exeDir, Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg'),
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

  /// То же, но по заранее собранному набору имён файлов папки — без
  /// existsSync() на каждый файл (при фильтрации целого списка это O(n²) IO).
  static bool hasMp4TwinIn(Set<String> fileNames, String fileName) {
    if (!_isConvertible(fileName)) return false;
    return fileNames.contains('${p.basenameWithoutExtension(fileName)}.mp4');
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
    final pending = <File>[];
    for (final f in toConvert) {
      final base = p.basenameWithoutExtension(f.path);
      final out = File(p.join(dir, '$base.mp4'));
      if (!out.existsSync() ||
          (!out.statSync().modified.isAfter(f.statSync().modified) &&
              !out.statSync().modified.isAtSameMomentAs(
                  f.statSync().modified)) ||
          !await _hasCurrentProfileMarker(dir, p.basename(f.path))) {
        pending.add(f);
      }
    }

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
      final tmp = File('$outPath.tmp.mp4');

      onProgress?.call(p.basename(src.path), i, pending.length);

      if (await tmp.exists()) await tmp.delete();

      AppLogger.log('ffmpeg: конвертирую ${p.basename(src.path)} → $base.mp4');
      Process? process;
      int exitCode = -1;
      String errStr = '';
      try {
        process = await Process.start(ffmpeg, [
          '-y',
          '-loglevel', 'error',
          '-i', src.path,
          '-map', '0:v:0',
          '-map', '0:a:0?',
          '-map_metadata', '-1',
          '-map_chapters', '-1',
          '-sn',
          '-dn',
          '-f', 'mp4',
          '-c:v', 'libx264',
          '-profile:v', 'baseline',
          '-level:v', '3.1',
          '-preset', 'veryfast',
          '-crf', '23',
          '-maxrate', '5000k',
          '-bufsize', '10000k',
          '-x264-params', 'bframes=0:ref=1',
          '-pix_fmt', 'yuv420p',
          '-colorspace', 'bt709',
          '-color_primaries', 'bt709',
          '-color_trc', 'bt709',
          '-vf',
          'scale=w=min(1280\\,iw):h=min(720\\,ih):force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709',
          '-c:a', 'aac',
          '-b:a', '128k',
          '-movflags', '+faststart',
          tmp.path,
        ]);

        final errBuffer = StringBuffer();
        final stdoutSub = process.stdout.listen((_) {});
        final stderrSub = process.stderr.transform(utf8.decoder).listen((data) {
          errBuffer.write(data);
          if (errBuffer.length > 2000) {
            errBuffer.clear();
            errBuffer.write('[truncated] ');
          }
        });

        exitCode = await process.exitCode;
        errStr = errBuffer.toString();

        await stdoutSub.cancel();
        await stderrSub.cancel();
      } catch (e) {
        if (process != null) {
          process.kill();
        }
        exitCode = -1;
        errStr = e.toString();
      }

      if (exitCode == 0 && await tmp.exists()) {
        final out = File(outPath);
        if (await out.exists()) await out.delete();
        await tmp.rename(outPath);
        await _writeProfileMarker(dir, p.basename(src.path));
        converted.add('$base.mp4');
        AppLogger.log('ffmpeg: готово $base.mp4');
      } else {
        failed.add(p.basename(src.path));
        if (await tmp.exists()) await tmp.delete();
        AppLogger.log(
            'ffmpeg: ошибка ${p.basename(src.path)} (код $exitCode): $errStr');
      }
    }

    await _rewritePlaylist(dir);
    return NormalizeResult(converted: converted, failed: failed);
  }

  static File _profileMarkerFile(String dir, String sourceName) {
    return File(p.join(dir, '.$sourceName.brandmen-conversion'));
  }

  static Future<bool> _hasCurrentProfileMarker(
      String dir, String sourceName) async {
    final marker = _profileMarkerFile(dir, sourceName);
    if (!await marker.exists()) return false;
    try {
      final text = await marker.readAsString();
      return text.trim() == '$_profileMarkerPrefix$_conversionProfileVersion';
    } catch (_) {
      return false;
    }
  }

  static Future<void> _writeProfileMarker(String dir, String sourceName) async {
    final marker = _profileMarkerFile(dir, sourceName);
    await marker.writeAsString(
        '$_profileMarkerPrefix$_conversionProfileVersion\n');
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
