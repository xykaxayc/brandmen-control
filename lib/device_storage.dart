import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

class SavedDevice {
  String ip;
  String name;
  String? deviceId;
  String? desiredDeploymentId;
  bool? desiredPlaybackEnabled;
  String? apiToken;

  SavedDevice({
    required this.ip,
    required this.name,
    this.deviceId,
    this.desiredDeploymentId,
    this.desiredPlaybackEnabled,
    this.apiToken,
  });

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'name': name,
        if (deviceId != null) 'device_id': deviceId,
        if (desiredDeploymentId != null)
          'desired_deployment_id': desiredDeploymentId,
        if (desiredPlaybackEnabled != null)
          'desired_playback_enabled': desiredPlaybackEnabled,
        if (apiToken != null) 'api_token': apiToken,
      };

  factory SavedDevice.fromJson(Map<String, dynamic> j) => SavedDevice(
        ip: j['ip'] as String,
        name: j['name'] as String,
        deviceId: j['device_id'] as String?,
        desiredDeploymentId: j['desired_deployment_id'] as String?,
        desiredPlaybackEnabled: j['desired_playback_enabled'] as bool?,
        apiToken: j['api_token'] as String?,
      );
}

class DeviceStorage {
  static const _key = 'saved_devices_v1';

  static bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left.codeUnitAt(i) ^ right.codeUnitAt(i);
    }
    return difference == 0;
  }

  static Future<List<SavedDevice>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => SavedDevice.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<SavedDevice> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(devices.map((d) => d.toJson()).toList()));
  }

  /// Разрешает фоновую перерегистрацию только уже известному планшету.
  ///
  /// Один deviceId не является секретом, поэтому для смены IP обязательно
  /// должен совпасть и случайный apiToken, полученный при первом сопряжении.
  static Future<bool> authenticate(String? deviceId, String? apiToken) async {
    if (deviceId == null ||
        deviceId.isEmpty ||
        apiToken == null ||
        apiToken.isEmpty) {
      return false;
    }
    final devices = await load();
    for (final device in devices) {
      final savedToken = device.apiToken;
      if (device.deviceId == deviceId &&
          savedToken != null &&
          savedToken.isNotEmpty &&
          _constantTimeEquals(savedToken, apiToken)) {
        return true;
      }
    }
    return false;
  }

  /// Одноразовая миграция старой записи, созданной до появления apiToken.
  /// Разрешаем её только для уже известного deviceId и только внутри той же
  /// IPv4 /24 сети. После регистрации [add] сохранит токен, и все следующие
  /// смены IP снова будут проходить строгую проверку authenticate().
  static Future<bool> canMigrateLegacyRegistration(
    String? deviceId,
    String? apiToken,
    String newIp,
  ) async {
    if (deviceId == null ||
        deviceId.isEmpty ||
        apiToken == null ||
        apiToken.isEmpty) {
      return false;
    }
    final devices = await load();
    for (final device in devices) {
      if (device.deviceId != deviceId) continue;
      if (device.apiToken?.isNotEmpty == true) return false;
      return _sameIpv4Subnet24(device.ip, newIp);
    }
    return false;
  }

  static bool _sameIpv4Subnet24(String left, String right) {
    final a = InternetAddress.tryParse(left);
    final b = InternetAddress.tryParse(right);
    if (a == null || b == null || a.type != b.type) return false;
    if (a.type != InternetAddressType.IPv4) return false;
    final ab = a.rawAddress;
    final bb = b.rawAddress;
    return ab[0] == bb[0] && ab[1] == bb[1] && ab[2] == bb[2];
  }

  static Future<void> add(
    String ip, {
    String? name,
    String? deviceId,
    String? apiToken,
  }) async {
    final list = await load();
    SavedDevice? byIdentity;
    SavedDevice? byIp;
    for (final device in list) {
      if (deviceId != null && device.deviceId == deviceId) {
        byIdentity = device;
      }
      if (device.ip == ip) byIp = device;
    }
    final existing = byIdentity ?? byIp;
    if (existing != null) {
      existing.ip = ip;
      existing.deviceId ??= deviceId;
      if (apiToken != null && apiToken.isNotEmpty) {
        existing.apiToken = apiToken;
      }
      if (name != null && name.trim().isNotEmpty) existing.name = name;
      await save(list);
      return;
    }
    list.add(SavedDevice(
      ip: ip,
      name: name ?? ip,
      deviceId: deviceId,
      apiToken: apiToken,
    ));
    await save(list);
  }

  static Future<void> updateIdentity(
    String ip, {
    String? deviceId,
  }) async {
    if (deviceId == null || deviceId.isEmpty) return;
    await add(ip, deviceId: deviceId);
  }

  static Future<void> setDesired(
      Iterable<String> ips, String deploymentId) async {
    final targets = ips.toSet();
    final list = await load();
    for (final device in list) {
      if (targets.contains(device.ip)) {
        device.desiredDeploymentId = deploymentId;
      }
    }
    await save(list);
  }

  /// Сохраняет операторское состояние показа отдельно от текущей доступности.
  /// Поэтому планшет, который был офлайн в момент «Запустить все», выполнит
  /// команду после возвращения в сеть, а смена IP не потеряет намерение.
  static Future<void> setDesiredPlayback(
      Iterable<String> ips, bool enabled) async {
    final targets = ips.toSet();
    final list = await load();
    var changed = false;
    for (final device in list) {
      if (!targets.contains(device.ip)) continue;
      if (device.desiredPlaybackEnabled != enabled) {
        device.desiredPlaybackEnabled = enabled;
        changed = true;
      }
    }
    if (changed) await save(list);
  }

  /// Убирает ожидание deployment после синхронизации через legacy-протокол.
  /// [expectedDeploymentId] защищает от стирания более нового запроса.
  static Future<void> clearDesired(
    Iterable<String> ips, {
    String? expectedDeploymentId,
  }) async {
    final targets = ips.toSet();
    final list = await load();
    var changed = false;
    for (final device in list) {
      if (!targets.contains(device.ip)) continue;
      if (expectedDeploymentId != null &&
          device.desiredDeploymentId != expectedDeploymentId) {
        continue;
      }
      if (device.desiredDeploymentId != null) {
        device.desiredDeploymentId = null;
        changed = true;
      }
    }
    if (changed) await save(list);
  }

  static Future<void> remove(String ip) async {
    final list = await load();
    list.removeWhere((d) => d.ip == ip);
    await save(list);
  }

  static Future<void> rename(String ip, String newName) async {
    final list = await load();
    final dev = list.firstWhere((d) => d.ip == ip,
        orElse: () => SavedDevice(ip: '', name: ''));
    if (dev.ip.isEmpty) return;
    dev.name = newName;
    await save(list);
  }
}
