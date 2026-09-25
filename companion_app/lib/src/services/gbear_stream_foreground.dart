import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'streaming_bridge.dart';

/// Android stream notification (Controller + Shortcuts) via native NotificationManager.
class GBearStreamNotification {
  GBearStreamNotification._();

  static const _channel = MethodChannel(StreamingBridge.channelName);

  static Future<bool> ensureNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    var status = await Permission.notification.status;
    if (!status.isGranted) {
      status = await Permission.notification.request();
    }
    return status.isGranted;
  }

  static Future<void> syncSession({
    required bool active,
    String? hostLabel,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('syncStreamNotification', {
        'active': active,
        'host': hostLabel ?? '',
      });
    } catch (_) {}
  }

  static Future<bool> consumePendingOpenMapping() async {
    if (!Platform.isAndroid) return false;
    try {
      final pending = await _channel.invokeMethod<bool>('consumePendingOpenMapping');
      return pending == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> showStreamMappingOverlay() async {
    if (!Platform.isAndroid) return false;
    try {
      final shown = await _channel.invokeMethod<bool>('showStreamMappingOverlay');
      return shown == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> consumePendingOpenShortcuts() async {
    if (!Platform.isAndroid) return false;
    try {
      final pending = await _channel.invokeMethod<bool>('consumePendingOpenShortcuts');
      return pending == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> showStreamShortcutsOverlay() async {
    if (!Platform.isAndroid) return false;
    try {
      final shown = await _channel.invokeMethod<bool>('showStreamShortcutsOverlay');
      return shown == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> fireStreamShortcut(List<int> moonlightKeyCodes) async {
    if (!Platform.isAndroid || moonlightKeyCodes.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('fireStreamShortcut', {
        'moonlightKeyCodes': moonlightKeyCodes,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }
}
