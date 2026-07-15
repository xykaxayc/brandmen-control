import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BrandPack {
  final String id;
  final String name;
  final String mark;
  final String kind;
  final Color accent;
  final String version;
  const BrandPack(
      this.id, this.name, this.mark, this.kind, this.accent, this.version);
}

/// Бренд-пакет — единый источник названия и акцентного цвета пульта.
/// Позже этот же JSON/asset-пакет будет отдаваться Android-плеерам.
class BrandPacks {
  static const available = <BrandPack>[
    BrandPack(
        'brandmen', 'BRANDMEN', 'B', 'Барбершоп', Color(0xFFE0B85C), 'v1.3'),
    BrandPack('mokko', 'MOKKO', 'M', 'Кофейня', Color(0xFF65C997), 'v2.1'),
    BrandPack(
        'fitline', 'FITLINE', 'F', 'Фитнес-студия', Color(0xFF7FA7FF), 'v1.0'),
  ];
  static const _key = 'brand_pack_id';
  static final current = ValueNotifier<BrandPack>(available.first);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_key);
    current.value =
        available.firstWhere((p) => p.id == id, orElse: () => available.first);
  }

  static Future<void> select(BrandPack pack) async {
    current.value = pack;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, pack.id);
  }
}
