import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SavedDevice {
  String ip;
  String name;
  String? deviceId;
  String? desiredDeploymentId;
  String? apiToken;

  SavedDevice({
    required this.ip,
    required this.name,
    this.deviceId,
    this.desiredDeploymentId,
    this.apiToken,
  });

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'name': name,
        if (deviceId != null) 'device_id': deviceId,
        if (desiredDeploymentId != null)
          'desired_deployment_id': desiredDeploymentId,
        if (apiToken != null) 'api_token': apiToken,
      };

  factory SavedDevice.fromJson(Map<String, dynamic> j) => SavedDevice(
        ip: j['ip'] as String,
        name: j['name'] as String,
        deviceId: j['device_id'] as String?,
        desiredDeploymentId: j['desired_deployment_id'] as String?,
        apiToken: j['api_token'] as String?,
      );
}

class DeviceStorage {
  static const _key = 'saved_devices_v1';

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
      existing.apiToken ??= apiToken;
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
