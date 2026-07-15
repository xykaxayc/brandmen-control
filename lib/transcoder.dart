import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'logger.dart';

/// Результат нормализации медиа-папки.
class NormalizeResult {
  final bool ffmpegMissing;
  final List<String> converted; // имена созданных mp4
  final List<String>
      failed; // имена исходников, которые не удалось сконвертировать
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

  // v4: один строгий профиль для ВСЕХ планшетов. При изменении этого номера
  // ранее подготовленные файлы пройдут проверку/перекодирование заново.
  static const _conversionProfileVersion = 4;
  static const _profileMarkerPrefix = '# Brandmen conversion profile ';

  // Целевые ограничения кадра — должны совпадать со scale в ffmpeg ниже.
  static const int _targetMaxW = 1280;
  static const int _targetMaxH = 720;

  static String? _cachedFfmpeg;
  static bool _searched = false;
  static String? _cachedFfprobe;
  static bool _searchedProbe = false;

  /// Не-mp4 контейнеры, которые надёжно НЕ играют на части Android-устройств и
  /// всегда конвертируются в mp4-двойник. (.mp4 сюда не входит: он остаётся с
  /// тем же именем, но проверяется на соответствие профилю через ffprobe.)
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

  /// Ищет бинарник ffprobe (нужен, чтобы заглянуть внутрь .mp4 и понять, надо
  /// ли его перекодировать). Обычно лежит рядом с ffmpeg.
  static Future<String?> findFfprobe() async {
    if (_searchedProbe) return _cachedFfprobe;
    _searchedProbe = true;
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final name = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    final candidates = <String>[
      p.join(exeDir, 'ffmpeg', name),
      p.join(exeDir, name),
      'ffprobe', // PATH
      '/opt/homebrew/bin/ffprobe',
      '/usr/local/bin/ffprobe',
      '/usr/bin/ffprobe',
      r'C:\ffmpeg\bin\ffprobe.exe',
      r'C:\Program Files\ffmpeg\bin\ffprobe.exe',
    ];
    for (final c in candidates) {
      try {
        final r = await Process.run(c, ['-version']);
        if (r.exitCode == 0) {
          _cachedFfprobe = c;
          AppLogger.log('ffprobe найден: $c');
          return c;
        }
      } catch (_) {
        // не найден по этому пути — пробуем следующий
      }
    }
    AppLogger.log(
        'ffprobe не найден — неподтверждённые mp4 будут перекодированы');
    _cachedFfprobe = null;
    return null;
  }

  /// Проверяет, соответствует ли готовый .mp4 целевому профилю (H.264 baseline,
  /// ≤1280×720, yuv420p, без B-кадров, звук AAC или без звука). Тогда
  /// перекодировать не нужно. Возвращает:
  ///  • true  — файл уже совместим;
  ///  • false — надо перекодировать;
  ///  • null  — не удалось проанализировать (ffprobe упал / файл битый) —
  ///            в этом случае оставляем файл как есть, чтобы не сломать рабочий.
  static Future<bool?> _isCompliantMp4(String ffprobe, String path) async {
    try {
      final r = await Process.run(ffprobe, [
        '-v',
        'error',
        '-print_format',
        'json',
        '-show_streams',
        path,
      ]);
      if (r.exitCode != 0) return null;
      final data = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      final streams = (data['streams'] as List?) ?? const [];
      var hasVideo = false;
      for (final s in streams.cast<Map<String, dynamic>>()) {
        final type = s['codec_type'];
        if (type == 'video') {
          hasVideo = true;
          if (s['codec_name'] != 'h264') return false;
          final profile = (s['profile'] as String?)?.toLowerCase() ?? '';
          if (!profile.contains('baseline')) return false;
          if (s['pix_fmt'] != 'yuv420p') return false;
          final w = (s['width'] as num?)?.toInt() ?? 0;
          final h = (s['height'] as num?)?.toInt() ?? 0;
          if (w == 0 || h == 0 || w > _targetMaxW || h > _targetMaxH) {
            return false;
          }
          final bFrames = (s['has_b_frames'] as num?)?.toInt() ?? 0;
          if (bFrames != 0) return false;
          // Фиксированный CFR: старые декодеры нестабильно играют VFR/29.97fps.
          if (s['r_frame_rate'] != '30/1') return false;
        } else if (type == 'audio') {
          if (s['codec_name'] != 'aac') return false;
          if (s['sample_rate'] != '48000') return false;
          if ((s['channels'] as num?)?.toInt() != 2) return false;
        }
      }
      return hasVideo;
    } catch (e) {
      AppLogger.log('ffprobe: не удалось проверить $path: $e');
      return null;
    }
  }

  /// Сбрасывает кэш поиска ffmpeg/ffprobe (если пользователь их доустановил).
  static void resetFfmpegCache() {
    _searched = false;
    _cachedFfmpeg = null;
    _searchedProbe = false;
    _cachedFfprobe = null;
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

  /// Приводит ВСЕ видео в папке к единому совместимому профилю:
  ///  • не-mp4 контейнеры (.mov/.mkv/.avi/.webm) → конвертирует в `<имя>.mp4`
  ///    (рядом, оригинал не удаляется);
  ///  • .mp4 → проверяет кодек через ffprobe и, если файл не соответствует
  ///    целевому профилю (HEVC/4K/high-profile/не-yuv420p/не-AAC и т.п.),
  ///    перекодирует его НА МЕСТЕ (с тем же именем).
  /// Уже приведённые файлы пропускаются (кэш по профиль-маркеру и mtime).
  /// После обработки переписывает playlist.m3u: не-mp4 имена → mp4.
  static Future<NormalizeResult> normalizeDir(
    String dir, {
    void Function(String file, int index, int total)? onProgress,
  }) async {
    final folder = Directory(dir);
    if (!await folder.exists()) return const NormalizeResult();

    final allFiles = folder.listSync().whereType<File>().toList();
    final allNames = allFiles.map((f) => p.basename(f.path)).toSet();

    // Собираем задания на перекодирование.
    final pending = <_ConvJob>[];

    // 1) Не-mp4 контейнеры → отдельный mp4-двойник.
    for (final f in allFiles) {
      final name = p.basename(f.path);
      if (name.startsWith('.')) continue;
      if (!_isConvertible(name)) continue;
      final base = p.basenameWithoutExtension(name);
      final out = File(p.join(dir, '$base.mp4'));
      final needs = !out.existsSync() ||
          (!out.statSync().modified.isAfter(f.statSync().modified) &&
              !out
                  .statSync()
                  .modified
                  .isAtSameMomentAs(f.statSync().modified)) ||
          !await _hasCurrentProfileMarker(dir, name);
      if (needs) {
        pending.add(_ConvJob(source: f, outPath: p.join(dir, '$base.mp4')));
      }
    }

    // 2) Сами .mp4 → проверяем кодек и, если не соответствует, перекодируем
    // на месте. Пропускаем те, у кого есть исходник-контейнер (их сделает п.1).
    String? ffprobe;
    for (final f in allFiles) {
      final name = p.basename(f.path);
      if (name.startsWith('.')) continue;
      if (p.extension(name).toLowerCase() != '.mp4') continue;
      final base = p.basenameWithoutExtension(name);
      final hasSource = convertExts.any((e) => allNames.contains('$base$e'));
      if (hasSource) continue;
      if (await _hasCurrentProfileMarker(dir, name)) continue;

      ffprobe ??= await findFfprobe();
      // Fail closed: неподтверждённый mp4 не уходит на планшет «как есть».
      // Без ffprobe или при ошибке чтения перекодируем его через ffmpeg.
      final compliant =
          ffprobe == null ? false : await _isCompliantMp4(ffprobe, f.path);
      if (compliant == true) {
        // Уже совместим — просто помечаем, чтобы не проверять каждый раз.
        await _writeProfileMarker(dir, name);
        continue;
      }
      // Битый/непроверяемый файл тоже пробуем перекодировать. Если ffmpeg не
      // справится, он попадёт в failed, и синхронизация будет остановлена.
      pending.add(_ConvJob(source: f, outPath: f.path));
    }

    if (pending.isEmpty) {
      // Всё уже приведено — просто убеждаемся, что плейлист на mp4.
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
      final job = pending[i];
      final src = job.source;
      final base = p.basenameWithoutExtension(job.outPath);
      final outPath = job.outPath;
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
          '-loglevel',
          'error',
          '-i',
          src.path,
          '-map',
          '0:v:0',
          '-map',
          '0:a:0?',
          '-map_metadata',
          '-1',
          '-map_chapters',
          '-1',
          '-sn',
          '-dn',
          '-f',
          'mp4',
          '-c:v',
          'libx264',
          '-profile:v',
          'baseline',
          '-level:v',
          '3.1',
          '-preset',
          'veryfast',
          '-crf',
          '23',
          '-maxrate',
          '5000k',
          '-bufsize',
          '10000k',
          '-x264-params',
          'bframes=0:ref=1',
          '-pix_fmt',
          'yuv420p',
          '-r',
          '30',
          '-colorspace',
          'bt709',
          '-color_primaries',
          'bt709',
          '-color_trc',
          'bt709',
          '-vf',
          'scale=w=min(1280\\,iw):h=min(720\\,ih):force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-ar',
          '48000',
          '-ac',
          '2',
          '-movflags',
          '+faststart',
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
    await marker
        .writeAsString('$_profileMarkerPrefix$_conversionProfileVersion\n');
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

/// Одно задание на перекодирование. Для не-mp4 источника [outPath] — отдельный
/// mp4-двойник; для .mp4 [outPath] равен пути источника (перекодирование на
/// месте с тем же именем).
class _ConvJob {
  final File source;
  final String outPath;
  const _ConvJob({required this.source, required this.outPath});
}
