import 'package:shared_preferences/shared_preferences.dart';

/// Persisted GBear stream host address (native protocol — no Sunshine).
class StreamingHostSettings {
  static const _hostKey = 'streaming.host.address';
  static const _httpPortKey = 'streaming.host.httpPort';
  static const _httpsPortKey = 'streaming.host.httpsPort';
  static const _controlPortKey = 'streaming.host.controlPort';

  /// GBear-native control plane (see GBearStreamPorts.swift).
  static const defaultControlPort = 28765;
  static const defaultVideoPort = 28766;
  static const defaultAudioPort = 28767;
  static const defaultAudioTcpPort = 28769;
  static const defaultInputPort = 28768;
  static const defaultHttpPort = defaultControlPort;
  static const defaultHttpsPort = defaultControlPort;

  final SharedPreferences _prefs;

  StreamingHostSettings(this._prefs);

  static Future<StreamingHostSettings> load() async {
    return StreamingHostSettings(await SharedPreferences.getInstance());
  }

  String get hostAddress => _prefs.getString(_hostKey) ?? '';

  int get httpPort => _prefs.getInt(_httpPortKey) ?? defaultHttpPort;

  int get httpsPort => _prefs.getInt(_httpsPortKey) ?? defaultHttpsPort;

  int get controlPort => _prefs.getInt(_controlPortKey) ?? defaultControlPort;

  Future<void> save({
    required String hostAddress,
    int? httpPort,
    int? httpsPort,
    int? controlPort,
  }) async {
    await _prefs.setString(_hostKey, hostAddress.trim());
    final port = controlPort ?? httpPort ?? defaultControlPort;
    await _prefs.setInt(_controlPortKey, port);
    await _prefs.setInt(_httpPortKey, httpPort ?? port);
    await _prefs.setInt(_httpsPortKey, httpsPort ?? port);
  }

  bool get isConfigured => hostAddress.isNotEmpty;

  Uri controlBase() => Uri(scheme: 'http', host: hostAddress, port: controlPort);
}
