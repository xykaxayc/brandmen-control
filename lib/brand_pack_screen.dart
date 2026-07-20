import 'package:flutter/material.dart';

import 'brand_pack.dart';

class BrandPackScreen extends StatelessWidget {
  final Future<void> Function(BrandPack pack) onSelect;

  const BrandPackScreen({super.key, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BrandPack>(
      valueListenable: BrandPacks.current,
      builder: (context, pack, _) {
        final accent = pack.accent;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(36, 32, 36, 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Бренд-пакет',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Оформление пульта и планшетов меняется одним пакетом.',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
              const SizedBox(height: 26),
              LayoutBuilder(builder: (context, constraints) {
                final narrow = constraints.maxWidth < 840;
                final overview = _overview(pack, accent);
                final contents = _contents(pack, accent);
                return narrow
                    ? Column(children: [
                        overview,
                        const SizedBox(height: 16),
                        contents,
                      ])
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 6, child: overview),
                          const SizedBox(width: 16),
                          Expanded(flex: 4, child: contents),
                        ],
                      );
              }),
              const SizedBox(height: 28),
              const Text(
                'ДОСТУПНЫЕ ПАКЕТЫ',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.3,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: BrandPacks.available
                    .map((item) => _packageCard(
                          item,
                          item.id == pack.id,
                          onTap: () => onSelect(item),
                        ))
                    .toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _overview(BrandPack pack, Color accent) {
    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _mark(pack, 64, 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pack.name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${pack.kind} · пакет ${pack.version} · активен',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'АКТУАЛЕН',
                style: TextStyle(
                  color: accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            )
          ]),
          const SizedBox(height: 20),
          Row(children: [
            _swatch(accent),
            const SizedBox(width: 8),
            _swatch(const Color(0xFF121215)),
            const SizedBox(width: 8),
            _swatch(const Color(0xFF26262A)),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'акцент бренда · нейтральные поверхности',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          Container(
            height: 190,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: RadialGradient(
                center: const Alignment(-.65, -.7),
                radius: 1.35,
                colors: [
                  accent.withValues(alpha: .34),
                  const Color(0xFF0B0B0D),
                ],
              ),
              border: Border.all(color: Colors.white10),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _mark(pack, 42, 19),
                  const SizedBox(height: 10),
                  Text(
                    pack.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2.5,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    pack.tagline,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  const SizedBox(height: 13),
                  const Text(
                    'Заставка планшета · ожидание контента',
                    style: TextStyle(color: Colors.white24, fontSize: 10),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () => onSelect(pack),
            icon: const Icon(Icons.sync_rounded, size: 18),
            label: const Text('Применить ко всем планшетам'),
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: const Color(0xFF101012),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _contents(BrandPack pack, Color accent) {
    final rows = <(IconData, String)>[
      (Icons.badge_outlined, 'Название и знак бренда'),
      (Icons.palette_outlined, 'Акцентный цвет интерфейса'),
      (Icons.tablet_android_rounded, 'Заставка планшетов'),
      (Icons.playlist_play_rounded, 'Оформление плейлиста'),
      (Icons.text_fields_rounded, 'Текст экрана без контента'),
    ];
    return _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ЧТО МЕНЯЕТ ПАКЕТ',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 14),
          ...rows.map((row) => Padding(
                padding: const EdgeInsets.only(bottom: 13),
                child: Row(children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .13),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(row.$1, color: accent, size: 16),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(row.$2,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                  ),
                  Icon(Icons.check_rounded, color: accent, size: 17),
                ]),
              )),
          const Divider(color: Colors.white10, height: 22),
          const Text(
            'Названия планшетов, сетевые настройки и локальные ролики остаются на уровне точки.',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _packageCard(BrandPack pack, bool active,
      {required VoidCallback onTap}) {
    return SizedBox(
      width: 230,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: active
                ? pack.accent.withValues(alpha: .10)
                : Colors.white.withValues(alpha: .035),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? pack.accent : Colors.white10,
              width: active ? 1.4 : 1,
            ),
          ),
          child: Row(children: [
            _mark(pack, 42, 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(pack.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14)),
                  const SizedBox(height: 3),
                  Text('${pack.kind} · ${pack.version}',
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
            if (active)
              Icon(Icons.check_circle_rounded, color: pack.accent, size: 18),
          ]),
        ),
      ),
    );
  }

  Widget _surface({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .04),
        border: Border.all(color: Colors.white.withValues(alpha: .075)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  Widget _mark(BrandPack pack, double size, double fontSize) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: pack.accent,
        borderRadius: BorderRadius.circular(size * .24),
      ),
      alignment: Alignment.center,
      child: Text(
        pack.mark,
        style: TextStyle(
          color: const Color(0xFF101012),
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _swatch(Color color) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white12),
      ),
    );
  }
}
