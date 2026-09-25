import 'package:shared_preferences/shared_preferences.dart';

/// Touchpad / cursor options for [GBearVideoActivity] (Android stream view).
class StreamTouchSettings {
  static const _cursorSpeedKey = 'stream.touch.cursorSpeed';
  static const _tapSlopKey = 'stream.touch.tapSlopPercent';
  static const _tapTimeoutKey = 'stream.touch.tapTimeoutMs';
  static const _tapPressureKey = 'stream.touch.tapPressurePercent';
  static const _swapStickSensitivityKey = 'stream.touch.swapStickSensitivity';

  StreamTouchSettings(this._prefs);

  final SharedPreferences _prefs;

  static Future<StreamTouchSettings> load() async {
    return StreamTouchSettings(await SharedPreferences.getInstance());
  }

  /// 0.25–3.0 — multiplies finger movement before sending to the Mac.
  double get cursorSpeed => _prefs.getDouble(_cursorSpeedKey) ?? 1.0;

  /// 50–200% of system touch slop — how far the finger can move and still count as a tap.
  int get tapSlopPercent => _prefs.getInt(_tapSlopKey) ?? 100;

  /// 150–800 ms — max press duration for a tap (vs click-drag).
  int get tapTimeoutMs => _prefs.getInt(_tapTimeoutKey) ?? 400;

  /// 10–90% — minimum touch pressure (Android) required to register a tap.
  int get tapPressurePercent => _prefs.getInt(_tapPressureKey) ?? 35;

  /// 0.05–1.0 — left stick cursor speed when notification **Swap** mouse mode is on.
  double get swapStickSensitivity =>
      _prefs.getDouble(_swapStickSensitivityKey) ?? 0.05;

  Future<void> save({
    double? cursorSpeed,
    int? tapSlopPercent,
    int? tapTimeoutMs,
    int? tapPressurePercent,
    double? swapStickSensitivity,
  }) async {
    if (cursorSpeed != null) {
      await _prefs.setDouble(
        _cursorSpeedKey,
        cursorSpeed.clamp(0.25, 3.0),
      );
    }
    if (tapSlopPercent != null) {
      await _prefs.setInt(_tapSlopKey, tapSlopPercent.clamp(50, 200));
    }
    if (tapTimeoutMs != null) {
      await _prefs.setInt(_tapTimeoutKey, tapTimeoutMs.clamp(150, 800));
    }
    if (tapPressurePercent != null) {
      await _prefs.setInt(_tapPressureKey, tapPressurePercent.clamp(10, 90));
    }
    if (swapStickSensitivity != null) {
      await _prefs.setDouble(
        _swapStickSensitivityKey,
        swapStickSensitivity.clamp(0.05, 1.0),
      );
    }
  }

  Map<String, dynamic> toMethodChannelMap() {
    return {
      'cursorSpeed': cursorSpeed,
      'tapSlopPercent': tapSlopPercent,
      'tapTimeoutMs': tapTimeoutMs,
      'tapPressurePercent': tapPressurePercent,
      'swapStickSensitivity': swapStickSensitivity,
    };
  }
}
