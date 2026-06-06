import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';

import 'vpn_service.dart';

/// Управляет иконкой в системном трее Windows.
/// Иконка меняется в зависимости от статуса VPN.
/// Меню: статус (disabled) + разделитель + Exit.
class TrayService with TrayListener {
  final VpnService _vpn;
  final VoidCallback onShowWindow;
  final VoidCallback onExit;

  TrayService({
    required VpnService vpn,
    required this.onShowWindow,
    required this.onExit,
  }) : _vpn = vpn;

  Future<void> initialize() async {
    if (!Platform.isWindows) return;

    trayManager.addListener(this);

    await _setIcon(_vpn.status);
    await _rebuildMenu();

    // Обновляем трей при каждом изменении статуса
    _vpn.addListener(_onVpnChanged);
  }

  void _onVpnChanged() {
    _setIcon(_vpn.status);
    _rebuildMenu();
  }

  Future<void> _setIcon(VpnStatus status) async {
    // Иконки лежат в assets/tray/
    // connected.ico — зелёный щит
    // disconnected.ico — серый щит
    // connecting.ico — жёлтый щит
    final icon = switch (status) {
      VpnStatus.connected    => 'assets/tray/connected.ico',
      VpnStatus.connecting   => 'assets/tray/connecting.ico',
      VpnStatus.disconnected => 'assets/tray/disconnected.ico',
      VpnStatus.error        => 'assets/tray/disconnected.ico',
    };

    await trayManager.setIcon(icon);

    final tooltip = switch (status) {
      VpnStatus.connected    => 'VPN — Подключено',
      VpnStatus.connecting   => 'VPN — Подключение...',
      VpnStatus.disconnected => 'VPN — Отключено',
      VpnStatus.error        => 'VPN — Ошибка',
    };
    await trayManager.setToolTip(tooltip);
  }

  Future<void> _rebuildMenu() async {
    final statusLabel = switch (_vpn.status) {
      VpnStatus.connected    => '🟢  Подключено',
      VpnStatus.connecting   => '🟡  Подключение...',
      VpnStatus.disconnected => '⚪  Отключено',
      VpnStatus.error        => '🔴  Ошибка',
    };

    final menu = Menu(items: [
      MenuItem(
        key: 'status',
        label: statusLabel,
        disabled: true,   // только информация, не кликабельно
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'exit',
        label: 'Выход',
      ),
    ]);

    await trayManager.setContextMenu(menu);
  }

  // ── TrayListener ──────────────────────────────────────────────────────────

  /// Одиночный клик — показываем главное окно
  @override
  void onTrayIconMouseDown() {
    onShowWindow();
  }

  /// Правый клик — показываем меню (Windows делает это автоматически,
  /// но на всякий случай дублируем)
  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'exit') {
      onExit();
    }
  }

  Future<void> dispose() async {
    if (!Platform.isWindows) return;
    _vpn.removeListener(_onVpnChanged);
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}