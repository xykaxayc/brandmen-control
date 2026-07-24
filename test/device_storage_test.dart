import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:brandmen_windows/device_storage.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('known device authenticates with both id and token', () async {
    await DeviceStorage.add(
      '192.168.1.10',
      name: 'Планшет 1',
      deviceId: 'tab-1',
      apiToken: 'secret-token',
    );

    expect(await DeviceStorage.authenticate('tab-1', 'secret-token'), isTrue);
    expect(await DeviceStorage.authenticate('tab-1', 'wrong-token'), isFalse);
    expect(
        await DeviceStorage.authenticate('wrong-id', 'secret-token'), isFalse);
    expect(await DeviceStorage.authenticate('tab-1', null), isFalse);
  });

  test('re-registration updates IP without duplicating device', () async {
    await DeviceStorage.add(
      '192.168.1.10',
      name: 'Планшет 1',
      deviceId: 'tab-1',
      apiToken: 'secret-token',
    );
    await DeviceStorage.add(
      '192.168.1.44',
      name: 'Xiaomi',
      deviceId: 'tab-1',
      apiToken: 'secret-token',
    );

    final devices = await DeviceStorage.load();
    expect(devices, hasLength(1));
    expect(devices.single.ip, '192.168.1.44');
    expect(devices.single.name, 'Xiaomi');
  });

  test('legacy sync clears only the deployment it actually attempted',
      () async {
    await DeviceStorage.add('192.168.1.10', name: 'Планшет 1');
    await DeviceStorage.setDesired(['192.168.1.10'], 'deployment-old');

    await DeviceStorage.clearDesired(
      ['192.168.1.10'],
      expectedDeploymentId: 'deployment-new',
    );
    expect((await DeviceStorage.load()).single.desiredDeploymentId,
        'deployment-old');

    await DeviceStorage.clearDesired(
      ['192.168.1.10'],
      expectedDeploymentId: 'deployment-old',
    );
    expect((await DeviceStorage.load()).single.desiredDeploymentId, isNull);
  });

  test('known legacy device may establish its first token after IP change',
      () async {
    await DeviceStorage.add(
      '192.168.1.150',
      name: 'Планшет',
      deviceId: 'tab-stable-id',
    );

    expect(
      await DeviceStorage.canMigrateLegacyRegistration(
        'tab-stable-id',
        'new-secret-token',
        '192.168.1.142',
      ),
      isTrue,
    );
    expect(
      await DeviceStorage.canMigrateLegacyRegistration(
        'tab-stable-id',
        'new-secret-token',
        '192.168.2.142',
      ),
      isFalse,
    );
  });

  test('device with a stored token cannot use legacy migration', () async {
    await DeviceStorage.add(
      '192.168.1.150',
      name: 'Планшет',
      deviceId: 'tab-stable-id',
      apiToken: 'original-token',
    );

    expect(
      await DeviceStorage.canMigrateLegacyRegistration(
        'tab-stable-id',
        'different-token',
        '192.168.1.142',
      ),
      isFalse,
    );
  });

  test('desired playback survives IP change by device identity', () async {
    await DeviceStorage.add(
      '192.168.1.150',
      name: 'Планшет',
      deviceId: 'tab-stable-id',
      apiToken: 'secret-token',
    );
    await DeviceStorage.setDesiredPlayback(['192.168.1.150'], true);

    await DeviceStorage.add(
      '192.168.1.142',
      name: 'Планшет',
      deviceId: 'tab-stable-id',
      apiToken: 'secret-token',
    );

    final device = (await DeviceStorage.load()).single;
    expect(device.ip, '192.168.1.142');
    expect(device.desiredPlaybackEnabled, isTrue);
  });

  test('desired playback is stored for offline devices', () async {
    await DeviceStorage.add('192.168.1.10', name: 'Первый');
    await DeviceStorage.add('192.168.1.11', name: 'Второй');

    await DeviceStorage.setDesiredPlayback(
        ['192.168.1.10', '192.168.1.11'], false);

    final devices = await DeviceStorage.load();
    expect(devices.map((d) => d.desiredPlaybackEnabled), everyElement(isFalse));
  });
}
