import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'media_config.dart';

const int kDeploymentProtocolVersion = 2;
const String kDeploymentCodecProfile = 'h264-baseline-3.1-v4';

class DeploymentFile {
  final String logicalName;
  final String sha256;
  final int size;

  const DeploymentFile({
    required this.logicalName,
    required this.sha256,
    required this.size,
  });

  Map<String, dynamic> toJson() => {
        'logical_name': logicalName,
        'sha256': sha256,
        'size': size,
        'codec_profile': kDeploymentCodecProfile,
      };
}

/// Неизменяемое описание одного набора контента.
///
/// [deploymentId] вычисляется только из значимого содержимого. Время создания
/// намеренно не участвует в хеше: одинаковые файлы и порядок всегда дают один
/// и тот же идентификатор.
class ContentDeployment {
  final String deploymentId;
  final String playlistHash;
  final DateTime createdAt;
  final List<DeploymentFile> files;
  final List<String> playlist;

  const ContentDeployment({
    required this.deploymentId,
    required this.playlistHash,
    required this.createdAt,
    required this.files,
    required this.playlist,
  });

  Map<String, dynamic> _identityJson() => {
        'protocol_version': kDeploymentProtocolVersion,
        'codec_profile': kDeploymentCodecProfile,
        'files': files.map((f) => f.toJson()).toList(),
        'playlist': playlist,
        'playlist_hash': playlistHash,
      };

  Map<String, dynamic> toJson() => {
        ..._identityJson(),
        'deployment_id': deploymentId,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  String encode() => jsonEncode(toJson());
}

class DeploymentBuilder {
  DeploymentBuilder._();

  static Future<ContentDeployment> fromMediaDirectory(String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) {
      throw StateError('Папка с роликами не найдена: $directory');
    }

    final playlistFile = File(p.join(directory, 'playlist.m3u'));
    if (!await playlistFile.exists()) {
      throw StateError('Не найден playlist.m3u');
    }

    final playlist = (await playlistFile.readAsLines())
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList(growable: false);
    if (playlist.isEmpty) {
      throw StateError('Плейлист пуст');
    }

    final uniqueNames = <String>{};
    final files = <DeploymentFile>[];
    for (final name in playlist) {
      if (p.basename(name) != name || name.contains('..')) {
        throw StateError('Недопустимое имя в плейлисте: $name');
      }
      if (!isVideoFile(name)) {
        throw StateError('Неподдерживаемый файл в плейлисте: $name');
      }
      if (!uniqueNames.add(name)) continue;
      final file = File(p.join(directory, name));
      if (!await file.exists()) {
        throw StateError('Файл из плейлиста не найден: $name');
      }
      final size = await file.length();
      if (size <= 0) throw StateError('Пустой видеофайл: $name');
      final digest = await sha256.bind(file.openRead()).first;
      files.add(DeploymentFile(
        logicalName: name,
        sha256: digest.toString(),
        size: size,
      ));
    }

    // Канонический порядок файлов не зависит от порядка обхода диска.
    files.sort((a, b) => a.logicalName.compareTo(b.logicalName));
    final playlistHash =
        sha256.convert(utf8.encode(playlist.join('\n'))).toString();
    final identity = <String, dynamic>{
      'protocol_version': kDeploymentProtocolVersion,
      'codec_profile': kDeploymentCodecProfile,
      'files': files.map((f) => f.toJson()).toList(),
      'playlist': playlist,
      'playlist_hash': playlistHash,
    };
    final deploymentId =
        sha256.convert(utf8.encode(jsonEncode(identity))).toString();

    return ContentDeployment(
      deploymentId: deploymentId,
      playlistHash: playlistHash,
      createdAt: DateTime.now().toUtc(),
      files: files,
      playlist: playlist,
    );
  }
}
