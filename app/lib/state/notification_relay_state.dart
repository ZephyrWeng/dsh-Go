// Listening to the phone's own notifications, so a plugin can act on them
// without a second app holding 通知使用权.
//
// Android only: the system binds notify/NotificationRelayService.kt once the
// person grants that access; the service posts each notification as JSON to
// http://127.0.0.1:<port>/notify. This file is the settings side — whether the
// access is granted, the switch, the port — and nothing of the forwarding.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where a plugin listens by default; the relay posts here until changed.
const notificationRelayDefaultPort = 38017;

class NotificationRelayStatus {
  const NotificationRelayStatus({
    required this.granted,
    required this.enabled,
    required this.port,
    this.last = '',
  });

  static const unsupported = NotificationRelayStatus(granted: false, enabled: false, port: notificationRelayDefaultPort);

  /// 通知使用权 lists this app. The person can revoke it without telling us.
  final bool granted;

  /// The switch: forwarding is on when this is on *and* [granted].
  final bool enabled;
  final int port;

  /// The last line the service wrote (sent, or why it could not).
  final String last;

  bool get forwarding => enabled && granted;

  NotificationRelayStatus copyWith({bool? granted, bool? enabled, int? port, String? last}) =>
      NotificationRelayStatus(
        granted: granted ?? this.granted,
        enabled: enabled ?? this.enabled,
        port: port ?? this.port,
        last: last ?? this.last,
      );
}

/// The native side, or null where this build has none (iOS, desktop).
abstract interface class NotificationRelayBridge {
  Future<NotificationRelayStatus?> status();
  Future<void> setEnabled(bool on);
  Future<void> setPort(int port);

  /// Opens the system's 通知使用权 page; false when the ROM has none.
  Future<bool> openSettings();
}

class MethodChannelNotificationRelay implements NotificationRelayBridge {
  static const _methods = MethodChannel('dsh/notify/relay');

  @override
  Future<NotificationRelayStatus?> status() async {
    try {
      final map = await _methods.invokeMapMethod<String, Object?>('status');
      if (map == null) return null;
      return NotificationRelayStatus(
        granted: map['granted'] == true,
        enabled: map['enabled'] == true,
        port: (map['port'] as num?)?.toInt() ?? notificationRelayDefaultPort,
        last: map['last'] as String? ?? '',
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> setEnabled(bool on) async {
    try {
      await _methods.invokeMethod<void>('setEnabled', {'on': on});
    } on MissingPluginException {
      // Nothing to set on a build without the native side.
    }
  }

  @override
  Future<void> setPort(int port) async {
    await _methods.invokeMethod<void>('setPort', {'port': port});
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await _methods.invokeMethod<bool>('openSettings') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

final notificationRelayBridgeProvider = Provider<NotificationRelayBridge>(
  (ref) => MethodChannelNotificationRelay(),
);

/// The current state; refresh by invalidating after a change or coming back
/// from the system page.
final notificationRelayStatusProvider = FutureProvider<NotificationRelayStatus>((ref) async {
  final status = await ref.watch(notificationRelayBridgeProvider).status();
  return status ?? NotificationRelayStatus.unsupported;
});

class NotificationRelayController {
  NotificationRelayController(this._ref);

  final Ref _ref;

  Future<void> setEnabled(bool on) async {
    await _ref.read(notificationRelayBridgeProvider).setEnabled(on);
    _ref.invalidate(notificationRelayStatusProvider);
  }

  Future<void> setPort(int port) async {
    await _ref.read(notificationRelayBridgeProvider).setPort(port);
    _ref.invalidate(notificationRelayStatusProvider);
  }

  Future<bool> openSettings() => _ref.read(notificationRelayBridgeProvider).openSettings();

  /// Re-read the grant, which may have changed while the person was in settings.
  void refresh() => _ref.invalidate(notificationRelayStatusProvider);
}

final notificationRelayControllerProvider = Provider<NotificationRelayController>(
  NotificationRelayController.new,
);
