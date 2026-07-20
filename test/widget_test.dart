// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:brandmen_windows/main.dart';
import 'package:brandmen_windows/brand_pack.dart';
import 'package:brandmen_windows/brand_pack_screen.dart';

void main() {
  testWidgets('Apple background wrapper renders child',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: AppleBackgroundWrapper(child: Text('Brandmen smoke')),
    ));
    await tester.pump();

    expect(find.text('Brandmen smoke'), findsOneWidget);
  });

  testWidgets('Brand pack screen fits desktop and applies selection',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      BrandPacks.current.value = BrandPacks.available.first;
    });

    BrandPack? selected;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: BrandPackScreen(onSelect: (pack) async {
          selected = pack;
          BrandPacks.current.value = pack;
        }),
      ),
    ));
    await tester.pump();

    expect(find.text('Бренд-пакет'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('MOKKO'));
    await tester.pump();
    expect(selected?.id, 'mokko');
    expect(tester.takeException(), isNull);
  });
}
