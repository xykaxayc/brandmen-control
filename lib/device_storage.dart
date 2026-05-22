import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SavedDevice {
  final String ip;
  String name;

  SavedDevice({required this.ip, required this.name});

  Map<String, dynamic> toJson() => {'ip': ip, 'name': name};

  factory SavedDevice.fromJson(Map<String, dynamic> j) =>
      SavedDevice(ip: j['ip'] as String, name: j['name'] as String);
}

class DeviceStorage {
  static const _key = 'saved_devices_v1';

  static Future<List<SavedDevice>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => SavedDevice.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<SavedDevice> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(devices.map((d) => d.toJson()).toList()));
  }

  static Future<void> add(String ip, {String? name}) async {
    final list = await load();
    if (list.any((d) => d.ip == ip)) return;
    list.add(SavedDevice(ip: ip, name: name ?? ip));
    await save(list);
  }

  static Future<void> remove(String ip) async {
    final list = await load();
    list.removeWhere((d) => d.ip == ip);
    await save(list);
  }

  static Future<void> rename(String ip, String newName) async {
    final list = await load();
    final dev = list.firstWhere((d) => d.ip == ip, orElse: () => SavedDevice(ip: '', name: ''));
    if (dev.ip.isEmpty) return;
    dev.name = newName;
    await save(list);
  }
}
