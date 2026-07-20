import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:brandmen_windows/deployment.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('brandmen-deployment-test-');
    await File(p.join(temp.path, 'one.mp4')).writeAsBytes([1, 2, 3, 4]);
    await File(p.join(temp.path, 'two.mp4')).writeAsBytes([5, 6, 7, 8]);
    await File(p.join(temp.path, 'playlist.m3u'))
        .writeAsString('#EXTM3U\none.mp4\ntwo.mp4\n');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('одинаковый контент получает стабильный deployment id', () async {
    final first = await DeploymentBuilder.fromMediaDirectory(temp.path);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final second = await DeploymentBuilder.fromMediaDirectory(temp.path);

    expect(second.deploymentId, first.deploymentId);
    expect(second.playlistHash, first.playlistHash);
    expect(first.files, hasLength(2));
  });

  test('изменение порядка создаёт новую версию', () async {
    final first = await DeploymentBuilder.fromMediaDirectory(temp.path);
    await File(p.join(temp.path, 'playlist.m3u'))
        .writeAsString('#EXTM3U\ntwo.mp4\none.mp4\n');
    final second = await DeploymentBuilder.fromMediaDirectory(temp.path);

    expect(second.deploymentId, isNot(first.deploymentId));
    expect(second.playlistHash, isNot(first.playlistHash));
  });

  test('новое содержимое того же размера создаёт новую версию', () async {
    final first = await DeploymentBuilder.fromMediaDirectory(temp.path);
    await File(p.join(temp.path, 'one.mp4')).writeAsBytes([9, 9, 9, 9]);
    final second = await DeploymentBuilder.fromMediaDirectory(temp.path);

    expect(second.deploymentId, isNot(first.deploymentId));
    expect(
        second.files.singleWhere((f) => f.logicalName == 'one.mp4').sha256,
        isNot(
            first.files.singleWhere((f) => f.logicalName == 'one.mp4').sha256));
  });

  test('отсутствующий файл из плейлиста блокирует публикацию', () async {
    await File(p.join(temp.path, 'playlist.m3u'))
        .writeAsString('#EXTM3U\nmissing.mp4\n');

    expect(
      () => DeploymentBuilder.fromMediaDirectory(temp.path),
      throwsA(isA<StateError>()),
    );
  });
}
