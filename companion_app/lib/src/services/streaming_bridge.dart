import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/host_info.dart';
import 'companion_device_identity.dart';
import 'pairing_cancellation.dart';
import 'playnite_host_client.dart';
import 'stream_controller_settings.dart';
import 'stream_touch_settings.dart';
import 'stream_debug_log.dart';
import 'streaming_host_settings.dart';

/// Discovery, consent pairing, and native video via Playnite protocol.
class StreamingBridge {
  static const String channelName = 'com.playnite.companion/streaming_bridge';

  StreamingBridge({
    MethodChannel? channel,
    PlayniteHostClient? hostClient,
    StreamingHostSettings? settings,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _settingsFuture = settings != null
            ? Future.value(settings)
            : StreamingHostSettings.load(),
        _hostClientOverride = hostClient;

  final MethodChannel _channel;
  final Future<StreamingHostSettings> _settingsFuture;
  final PlayniteHostClient? _hostClientOverride;

  static const Duration _nativeCallTimeout = Duration(seconds: 15);

  bool? _iosSimulatorCached;

  Future<bool> _isIosSimulator() async {
    if (!Platform.isIOS) return false;
    _iosSimulatorCached ??= await _invokeNative<bool>('isSimulator') == true;
    return _iosSimulatorCached!;
  }

  Future<String> _resolveVideoHost(StreamStartOutcome outcome) async {
    if (await _isIosSimulator()) {
      return outcome.loopbackHost ?? '127.0.0.1';
    }
    return outcome.host!;
  }

  Future<T?> _invokeNative<T>(String method, [Object? arguments]) {
    return _channel
        .invokeMethod<T>(method, arguments)
        .timeout(_nativeCallTimeout, onTimeout: () {
      throw PlatformException(
        code: 'timeout',
        message: 'Native streaming call "$method" timed out.',
      );
    });
  }

  Future<PlayniteHostClient> _client() async {
    final override = _hostClientOverride;
    if (override != null) return override;
    final settings = await _settingsFuture;
    return PlayniteHostClient(settings);
  }

  Future<List<HostInfo>> discoverHosts() async {
    final client = await _client();
    return client.discoverHosts();
  }

  Future<List<Map<String, dynamic>>> autoMapCoopPads({bool swapFaceButtons = false}) async {
    try {
      final raw = await _invokeNative<List<dynamic>>('autoMapCoopPads', {
        'swapFaceButtons': swapFaceButtons,
      });
      if (raw == null) return const [];
      return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> listCoopPadMappings() async {
    try {
      final raw = await _invokeNative<List<dynamic>>('listCoopPadMappings');
      if (raw == null) return const [];
      return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, dynamic>?> applyCoopPadOverride({
    required String guid,
    required String logical,
    required int keyCode,
    String deviceName = '',
    int axis = -1,
    bool invert = false,
  }) async {
    try {
      final raw = await _invokeNative<Map<Object?, Object?>>('applyCoopPadOverride', {
        'guid': guid,
        'logical': logical,
        'keyCode': keyCode,
        'deviceName': deviceName,
        'axis': axis,
        'invert': invert,
      });
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> resetCoopPadMapping(String guid) async {
    try {
      await _invokeNative<void>('resetCoopPadMapping', {'guid': guid});
    } catch (_) {}
  }

  Future<List<ConnectedControllerInfo>> listConnectedControllers() async {
    try {
      final raw = await _invokeNative<List<dynamic>>('listConnectedControllers');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((entry) => ConnectedControllerInfo.fromMap(entry))
          .where((controller) => controller.id.isNotEmpty)
          .toList();
    } on PlatformException {
      return const [];
    } catch (_) {
      return const [];
    }
  }

  Future<PairingOutcome> pairWithHost({
    required String hostId,
    void Function(String status)? onProgress,
    PairingCancellation? cancellation,
  }) async {
    final client = await _client();
    return client.requestPair(onProgress: onProgress, cancellation: cancellation);
  }

  Future<void> cancelPairing() async {
    final client = await _client();
    final deviceId = await CompanionDeviceIdentity.deviceId();
    await client.cancelPairRequest(deviceId);
  }

  Future<Map<String, dynamic>> getStreamSession() async {
    try {
      final raw = await _invokeNative<Map<Object?, Object?>>('getStreamSession');
      if (raw == null) return const {};
      return Map<String, dynamic>.from(raw);
    } catch (_) {
      return const {};
    }
  }

  Future<void> clearPendingExternalStopLog() async {
    try {
      await _invokeNative<void>('clearPendingExternalStopLog');
    } catch (_) {}
  }

  Future<bool> resumeStream() async {
    try {
      final resumed = await _invokeNative<bool>('resumeStream');
      return resumed == true;
    } catch (_) {
      return false;
    }
  }

  Future<GamepadButtonPress?> awaitGamepadButtonPress({
    required String elementId,
    int timeoutMs = 15000,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'awaitGamepadButtonPress',
        {'timeoutMs': timeoutMs, 'elementId': elementId},
      );
      if (raw == null) return null;
      return GamepadButtonPress(
        keyCode: (raw['keyCode'] as num?)?.toInt() ?? 0,
        label: raw['label']?.toString() ?? 'Button',
        elementId: raw['elementId']?.toString(),
        guid: raw['guid']?.toString() ?? '',
        deviceName: raw['deviceName']?.toString() ?? '',
      );
    } on PlatformException {
      return null;
    }
  }

  Future<void> cancelGamepadButtonPress() async {
    try {
      await _channel.invokeMethod<void>('cancelGamepadButtonPress');
    } catch (_) {}
  }

  Future<void> prepareForNewStream() async {
    try {
      await _invokeNative<void>('prepareForNewStream');
    } catch (_) {}
  }

  Future<StreamStartOutcome> startStream({
    required String hostId,
    required int width,
    required int height,
    required int fps,
    StreamControllerSettings? controllerSettings,
    StreamTouchSettings? touchSettings,
    String? controllerBindingsJson,
    int? preferredSeat,
    bool? playAsHost,
  }) async {
    playniteStreamDebug('prepareForNewStream…');
    await prepareForNewStream();
    final client = await _client();
    final settings = controllerSettings ?? await StreamControllerSettings.load();
    playniteStreamDebug('POST Mac stream/start ${width}x$height @ ${fps}fps…');
    final asHost = playAsHost ?? settings.playAsHost;
    final outcome = await client.startStream(
      width: width,
      height: height,
      fps: fps,
      preferredSeat: asHost
          ? null
          : (preferredSeat ??
              (settings.preferredSeat == 0 ? null : settings.preferredSeat)),
      playAsHost: asHost,
    );
    if (!outcome.ok || outcome.host == null || outcome.videoPort == null) {
      playniteStreamDebug('Mac stream/start failed: ${outcome.message}');
      return outcome;
    }
    final videoHost = await _resolveVideoHost(outcome);
    playniteStreamDebug(
      'Mac capture started; opening native player $videoHost:${outcome.videoPort} seat=${outcome.seat}'
      '${videoHost != outcome.host ? " (LAN ${outcome.host})" : ""}',
    );

    try {
      final touch = touchSettings ?? await StreamTouchSettings.load();
      playniteStreamDebug('native startStream…');
      final started = await _invokeNative<bool>('startStream', {
        'host': videoHost,
        'videoPort': outcome.videoPort,
        'audioPort': outcome.audioPort ?? StreamingHostSettings.defaultAudioPort,
        'audioTcpPort': outcome.audioTcpPort ?? StreamingHostSettings.defaultAudioTcpPort,
        'inputPort': outcome.inputPort ?? StreamingHostSettings.defaultInputPort,
        'width': outcome.width ?? width,
        'height': outcome.height ?? height,
        'controllerBindingsJson': controllerBindingsJson ?? '',
        'seat': outcome.seat ?? 1,
        'coopPadMode': settings.coopPadMode,
        'swapFaceButtons': settings.swapFaceButtons,
        'deadZonePercent': settings.deadZonePercent,
        ...touch.toMethodChannelMap(),
      });
      if (started == true) {
        playniteStreamDebug('native startStream ok');
        return outcome;
      }
      playniteStreamDebug('native startStream returned false');
      await client.stopStreamOnHost();
      return StreamStartOutcome.failed('Native video player failed to start.');
    } on PlatformException catch (e) {
      playniteStreamDebug('native startStream error: ${e.code} ${e.message}');
      await client.stopStreamOnHost();
      return StreamStartOutcome.failed(e.message ?? 'Native stream error');
    }
  }

  /// Best-effort Mac teardown (notification Stop may have already called native HTTP stop).
  Future<void> updateSwapStickSensitivity(double sensitivity) async {
    try {
      await _channel.invokeMethod<void>('updateSwapStickSensitivity', {
        'swapStickSensitivity': sensitivity,
      });
    } catch (_) {}
  }

  Future<void> ensureHostStreamStopped() async {
    final client = await _client();
    await client.stopStreamOnHost();
    await client.waitForMacStreamIdle();
  }

  /// Wait until the Mac control API reports streaming has ended (use after Stop).
  Future<void> waitForHostStreamIdle() async {
    final client = await _client();
    await client.waitForMacStreamIdle();
  }

  /// Android: notification Stop and other native paths invoke [onStreamStoppedExternally].
  void installExternalStopListener(
    Future<void> Function({String? logPath}) onStopped,
  ) {
    _channel.setMethodCallHandler((call) {
      if (call.method == 'onStreamStoppedExternally') {
        String? logPath;
        final args = call.arguments;
        if (args is Map) {
          final raw = args['logPath'];
          if (raw is String && raw.isNotEmpty) {
            logPath = raw;
          }
        }
        // Synchronous handler — async handlers still make Android wait for the Future.
        scheduleMicrotask(() => unawaited(onStopped(logPath: logPath)));
      }
      return Future.value(null);
    });
  }

  /// Stops the Mac host and native player. Returns a log file path when the native layer wrote one.
  Future<String?> stopStream() async {
    try {
      final raw = await _invokeNative<Map<Object?, Object?>>('stopStream');
      final path = raw?['logPath'];
      if (path is String && path.isNotEmpty) {
        return path;
      }
    } catch (_) {}
    return null;
  }
}

class GamepadButtonPress {
  const GamepadButtonPress({
    required this.keyCode,
    required this.label,
    this.elementId,
    this.guid = '',
    this.deviceName = '',
  });

  final int keyCode;
  final String label;
  final String? elementId;
  final String guid;
  final String deviceName;
}
