import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'companion_device_identity.dart';

/// Client for hosted GBear session coordinator (Google/dev auth, invites, TURN, signaling).
class GBearSessionClient {
  GBearSessionClient(this._prefs);

  final SharedPreferences _prefs;

  static const _baseKey = 'gbear.session.baseUrl';
  static const _tokenKey = 'gbear.session.idToken';
  static const _emailKey = 'gbear.session.email';
  static const _sessionKey = 'gbear.session.remoteSessionId';

  static Future<GBearSessionClient> load() async {
    return GBearSessionClient(await SharedPreferences.getInstance());
  }

  String get baseUrl => _prefs.getString(_baseKey) ?? 'http://127.0.0.1:8787';

  String? get idToken => _prefs.getString(_tokenKey);

  String? get email => _prefs.getString(_emailKey);

  String? get remoteSessionId => _prefs.getString(_sessionKey);

  bool get isSignedIn => idToken != null && idToken!.isNotEmpty;

  Future<void> setBaseUrl(String url) async {
    await _prefs.setString(_baseKey, url);
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    return base.replace(path: path, queryParameters: query);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (idToken != null) 'Authorization': 'Bearer $idToken',
      };

  /// Use `dev:you@gmail.com` when the coordinator runs with GBEAR_DEV_AUTH=1.
  Future<bool> signIn(String idToken) async {
    await _prefs.setString(_tokenKey, idToken);
    final deviceId = await CompanionDeviceIdentity.deviceId();
    final deviceName = await CompanionDeviceIdentity.deviceName();
    try {
      final response = await http
          .post(
            _uri('/v1/auth/register-device'),
            headers: _headers,
            body: jsonEncode({
              'deviceId': deviceId,
              'deviceName': deviceName,
              'role': 'companion',
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        await _prefs.remove(_tokenKey);
        return false;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final email = json['email'] as String?;
      if (email != null) await _prefs.setString(_emailKey, email);
      return json['ok'] == true;
    } catch (_) {
      await _prefs.remove(_tokenKey);
      return false;
    }
  }

  Future<void> signOut() async {
    await _prefs.remove(_tokenKey);
    await _prefs.remove(_emailKey);
    await _prefs.remove(_sessionKey);
  }

  Future<Map<String, dynamic>?> redeemInvite(String inviteCode) async {
    final deviceId = await CompanionDeviceIdentity.deviceId();
    final deviceName = await CompanionDeviceIdentity.deviceName();
    try {
      final response = await http
          .post(
            _uri('/v1/session/redeem-invite'),
            headers: _headers,
            body: jsonEncode({
              'inviteCode': inviteCode.trim().toUpperCase(),
              'deviceId': deviceId,
              'deviceName': deviceName,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final session = json['session'] as Map<String, dynamic>?;
      final sessionId = session?['sessionId'] as String?;
      if (sessionId != null) await _prefs.setString(_sessionKey, sessionId);
      return json;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> joinOwnSession(String sessionId, {int? preferredSeat}) async {
    final deviceId = await CompanionDeviceIdentity.deviceId();
    final deviceName = await CompanionDeviceIdentity.deviceName();
    try {
      final body = <String, dynamic>{
        'sessionId': sessionId,
        'deviceId': deviceId,
        'deviceName': deviceName,
      };
      if (preferredSeat != null) body['preferredSeat'] = preferredSeat;
      final response = await http
          .post(
            _uri('/v1/session/join'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      await _prefs.setString(_sessionKey, sessionId);
      return json;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> fetchIceServers() async {
    try {
      final response = await http
          .post(_uri('/v1/turn/credentials'), headers: _headers, body: '{}')
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return const [];
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final servers = json['iceServers'];
      if (servers is! List) return const [];
      return servers.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> sendSignal({
    required String sessionId,
    required String toDeviceId,
    required Map<String, dynamic> payload,
  }) async {
    final deviceId = await CompanionDeviceIdentity.deviceId();
    try {
      await http
          .post(
            _uri('/v1/signal'),
            headers: _headers,
            body: jsonEncode({
              'sessionId': sessionId,
              'fromDeviceId': deviceId,
              'toDeviceId': toDeviceId,
              'payload': payload,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }
}
