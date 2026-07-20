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
}
