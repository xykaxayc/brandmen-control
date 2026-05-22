import 'package:flutter/material.dart';
import 'package:system_tray/system_tray.dart';
import 'dart:io';

class TrayManager {
  final SystemTray _systemTray = SystemTray();
  final AppWindow _appWindow = AppWindow();

  Future<void> init(VoidCallback onShow) async {
    String iconPath = Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png';

    await _systemTray.initSystemTray(
      title: "Brandmen Pro",
      iconPath: iconPath,
    );

    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: 'Открыть панель', onClicked: (menuItem) {
        _appWindow.show();
        onShow();
      }),
      MenuSeparator(),
      MenuItemLabel(label: 'Выйти', onClicked: (menuItem) => exit(0)),
    ]);

    await _systemTray.setContextMenu(menu);

    // Обработка клика по иконке в трее
    _systemTray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        _appWindow.show();
        onShow();
      } else if (eventName == kSystemTrayEventRightClick) {
        _systemTray.popUpContextMenu();
      }
    });
  }

  void hideToTray() {
    _appWindow.hide();
  }
}
