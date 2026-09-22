import 'package:shared_preferences/shared_preferences.dart';

/// Moonlight stream controller options (applied natively when a session starts).
class StreamControllerSettings {
  static const _multiControllerKey = 'stream.controller.multiController';
  static const _swapFaceButtonsKey = 'stream.controller.swapFaceButtons';
  static const _onScreenControlsKey = 'stream.controller.onScreenControls';
  static const _deadZoneKey = 'stream.controller.deadZone';
  static const _usbDriverKey = 'stream.controller.usbDriver';
  static const _bindAllUsbKey = 'stream.controller.bindAllUsb';
  static const _coopPadModeKey = 'stream.controller.coopPadMode';

  static const _preferredSeatKey = 'stream.controller.preferredSeat';
  static const _playAsHostKey = 'stream.controller.playAsHost';

  StreamControllerSettings(this._prefs);

  final SharedPreferences _prefs;

  static Future<StreamControllerSettings> load() async {
    return StreamControllerSettings(await SharedPreferences.getInstance());
  }

  bool get multiController => _prefs.getBool(_multiControllerKey) ?? true;

  bool get swapFaceButtons => _prefs.getBool(_swapFaceButtonsKey) ?? false;

  bool get onScreenControls => _prefs.getBool(_onScreenControlsKey) ?? false;

  int get deadZonePercent => _prefs.getInt(_deadZoneKey) ?? 7;

  /// Android: use Moonlight USB driver for USB-attached pads (e.g. USB-C telescopic).
  bool get usbDriver => _prefs.getBool(_usbDriverKey) ?? true;

  /// Android: claim USB devices Moonlight does not recognize by default.
  bool get bindAllUsb => _prefs.getBool(_bindAllUsbKey) ?? false;

  /// When true, stream sends PNG1 gamepad state to Mac virtual pads (co-op).
  /// When false, use keyboard-chord mappings (single-player / OS shortcuts).
  bool get coopPadMode => _prefs.getBool(_coopPadModeKey) ?? true;

  /// 1…8, or 0 for join order (next open seat after the host).
  int get preferredSeat => _prefs.getInt(_preferredSeatKey) ?? 0;

  /// When true, this companion claims Player 1 in place of the host Mac.
  bool get playAsHost => _prefs.getBool(_playAsHostKey) ?? false;

  Future<void> save({
    bool? multiController,
    bool? swapFaceButtons,
    bool? onScreenControls,
    int? deadZonePercent,
    bool? usbDriver,
    bool? bindAllUsb,
    bool? coopPadMode,
    int? preferredSeat,
    bool? playAsHost,
  }) async {
    if (multiController != null) {
      await _prefs.setBool(_multiControllerKey, multiController);
    }
    if (swapFaceButtons != null) {
      await _prefs.setBool(_swapFaceButtonsKey, swapFaceButtons);
    }
    if (onScreenControls != null) {
      await _prefs.setBool(_onScreenControlsKey, onScreenControls);
    }
    if (deadZonePercent != null) {
      await _prefs.setInt(_deadZoneKey, deadZonePercent.clamp(0, 20));
    }
    if (usbDriver != null) {
      await _prefs.setBool(_usbDriverKey, usbDriver);
    }
    if (bindAllUsb != null) {
      await _prefs.setBool(_bindAllUsbKey, bindAllUsb);
    }
    if (coopPadMode != null) {
      await _prefs.setBool(_coopPadModeKey, coopPadMode);
    }
    if (preferredSeat != null) {
      await _prefs.setInt(_preferredSeatKey, preferredSeat.clamp(0, 8));
    }
    if (playAsHost != null) {
      await _prefs.setBool(_playAsHostKey, playAsHost);
    }
  }

  Map<String, dynamic> toMethodChannelMap() {
    return {
      'multiController': multiController,
      'swapFaceButtons': swapFaceButtons,
      'onScreenControls': onScreenControls,
      'deadZonePercent': deadZonePercent,
      'usbDriver': usbDriver,
      'bindAllUsb': bindAllUsb,
      'coopPadMode': coopPadMode,
      'preferredSeat': preferredSeat,
      'playAsHost': playAsHost,
    };
  }
}

class DetectedGamepadButton {
  const DetectedGamepadButton({
    required this.keyCode,
    required this.label,
    this.elementId,
  });

  final int keyCode;
  final String label;
  final String? elementId;

  factory DetectedGamepadButton.fromMap(Map<dynamic, dynamic> map) {
    return DetectedGamepadButton(
      keyCode: (map['keyCode'] as num?)?.toInt() ?? 0,
      label: map['label']?.toString() ?? 'Button',
      elementId: map['elementId']?.toString(),
    );
  }
}

class ConnectedControllerInfo {
  const ConnectedControllerInfo({
    required this.id,
    required this.name,
    this.vendor,
    this.product,
    this.guid,
    this.detectedButtons = const [],
  });

  final String id;
  final String name;
  final String? vendor;
  final String? product;
  final String? guid;
  final List<DetectedGamepadButton> detectedButtons;

  factory ConnectedControllerInfo.fromMap(Map<dynamic, dynamic> map) {
    final rawButtons = map['detectedButtons'];
    final buttons = rawButtons is List
        ? rawButtons
            .whereType<Map>()
            .map((e) => DetectedGamepadButton.fromMap(e))
            .where((b) => b.keyCode != 0)
            .toList()
        : const <DetectedGamepadButton>[];
    return ConnectedControllerInfo(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Controller',
      vendor: map['vendor']?.toString(),
      product: map['product']?.toString(),
      guid: map['guid']?.toString(),
      detectedButtons: buttons,
    );
  }
}
