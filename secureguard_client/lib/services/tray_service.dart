import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'ipc_client.dart';

/// System tray service for SecureGuard VPN
class TrayService with TrayListener {
  static final TrayService _instance = TrayService._();
  static TrayService get instance => _instance;

  TrayService._();

  VpnConnectionState _currentState = VpnConnectionState.disconnected;
  VoidCallback? onConnectRequested;
  VoidCallback? onDisconnectRequested;
  VoidCallback? onQuitRequested;

  /// Initialize the system tray
  Future<void> init() async {
    trayManager.addListener(this);

    // Set initial icon
    await _updateTrayIcon(VpnConnectionState.disconnected);
    await _updateTrayMenu();
  }

  /// Update tray based on VPN status
  Future<void> updateStatus(VpnStatus status) async {
    if (_currentState != status.state) {
      _currentState = status.state;
      await _updateTrayIcon(status.state);
      await _updateTrayMenu();
    }
  }

  /// Update the tray icon based on connection state
  Future<void> _updateTrayIcon(VpnConnectionState state) async {
    String iconName;
    switch (state) {
      case VpnConnectionState.connected:
        iconName = 'icon_connected';
      case VpnConnectionState.connecting:
      case VpnConnectionState.disconnecting:
        iconName = 'icon_connecting';
      case VpnConnectionState.error:
        iconName = 'icon_error';
      case VpnConnectionState.disconnected:
        iconName = 'icon_disconnected';
    }

    // Use platform-specific icon format
    String iconPath;
    if (Platform.isMacOS) {
      iconPath = 'assets/icons/$iconName.png';
    } else if (Platform.isWindows) {
      iconPath = 'assets/icons/$iconName.ico';
    } else {
      iconPath = 'assets/icons/$iconName.png';
    }

    // Check if custom icon exists, otherwise use default
    try {
      await trayManager.setIcon(iconPath);
    } catch (e) {
      // Fall back to no custom icon - tray still works
    }

    // Set tooltip
    final tooltip = switch (state) {
      VpnConnectionState.connected => 'SecureGuard VPN - Connected',
      VpnConnectionState.connecting => 'SecureGuard VPN - Connecting...',
      VpnConnectionState.disconnecting => 'SecureGuard VPN - Disconnecting...',
      VpnConnectionState.error => 'SecureGuard VPN - Error',
      VpnConnectionState.disconnected => 'SecureGuard VPN - Disconnected',
    };

    await trayManager.setToolTip(tooltip);
  }

  /// Update the tray context menu
  Future<void> _updateTrayMenu() async {
    final isConnected = _currentState == VpnConnectionState.connected;
    final isTransitioning = _currentState == VpnConnectionState.connecting ||
        _currentState == VpnConnectionState.disconnecting;

    final menu = Menu(
      items: [
        MenuItem(
          label: 'SecureGuard VPN',
          disabled: true,
        ),
        MenuItem.separator(),
        MenuItem(
          label: _getStatusLabel(),
          disabled: true,
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'show',
          label: 'Show Window',
        ),
        MenuItem.separator(),
        if (isConnected)
          MenuItem(
            key: 'disconnect',
            label: 'Disconnect',
            disabled: isTransitioning,
          )
        else
          MenuItem(
            key: 'connect',
            label: 'Connect',
            disabled: isTransitioning,
          ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: 'Quit',
        ),
      ],
    );

    await trayManager.setContextMenu(menu);
  }

  String _getStatusLabel() {
    return switch (_currentState) {
      VpnConnectionState.connected => 'Status: Connected',
      VpnConnectionState.connecting => 'Status: Connecting...',
      VpnConnectionState.disconnecting => 'Status: Disconnecting...',
      VpnConnectionState.error => 'Status: Error',
      VpnConnectionState.disconnected => 'Status: Disconnected',
    };
  }

  @override
  void onTrayIconMouseDown() {
    // Show window on left click
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    // Show context menu on right click
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        windowManager.show();
        windowManager.focus();
      case 'connect':
        onConnectRequested?.call();
      case 'disconnect':
        onDisconnectRequested?.call();
      case 'quit':
        onQuitRequested?.call();
    }
  }

  /// Dispose the tray service
  Future<void> dispose() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}
