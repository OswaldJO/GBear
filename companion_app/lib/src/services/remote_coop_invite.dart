import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A host Mac's remote co-op invite line: `GBEAR1 <code> <https tunnel address>`.
///
/// The address reaches the relay running on the host Mac. The phone signs in, redeems the code for
/// the session id, then opens one WebSocket that carries video, audio, and controller frames.
class RemoteCoopInvite {
  const RemoteCoopInvite._(this.code, this.baseUrl);

  final String code;
  final Uri baseUrl;

  static const _timeout = Duration(seconds: 20);

  /// Accepts the full line, or just `<code> <address>`.
  static RemoteCoopInvite? parse(String raw) {
    final parts = raw.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    String code;
    String address;
    if (parts.length >= 3 && parts[0].toUpperCase() == 'GBEAR1') {
      code = parts[1];
      address = parts[2];
    } else if (parts.length >= 2 && parts[1].contains('://')) {
      code = parts[0];
      address = parts[1];
    } else {
      return null;
    }
    while (address.endsWith('/')) {
      address = address.substring(0, address.length - 1);
    }
    final url = Uri.tryParse(address);
    if (url == null || url.host.isEmpty || !(url.scheme == 'https' || url.scheme == 'http')) {
      return null;
    }
    return RemoteCoopInvite._(code.toUpperCase(), url);
  }

  /// Redeems the code and returns the relay WebSocket address for this device.
  Future<Uri> join({required String deviceId, required String deviceName}) async {
    await _post('/v1/auth/register-device', {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'role': 'guest',
    });
    final json = await _post('/v1/session/redeem-invite', {
      'inviteCode': code,
      'deviceId': deviceId,
      'deviceName': deviceName,
    });
    final session = json['session'];
    final sessionId = session is Map ? session['sessionId'] as String? : null;
    if (sessionId == null || sessionId.isEmpty) {
      throw const RemoteCoopJoinException('That invite was not accepted. Ask your friend for a new invite line.');
    }
    return baseUrl.replace(
      scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
      path: '/v1/ws',
      queryParameters: {'deviceId': deviceId, 'sessionId': sessionId, 'mode': 'relay'},
    );
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final http.Response response;
    try {
      response = await http
          .post(
            baseUrl.replace(path: path),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer dev:guest@gbear.local',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const RemoteCoopJoinException(
        'Your friend\'s Mac did not answer. Check that remote co-op is still running there.',
      );
    } catch (_) {
      throw const RemoteCoopJoinException(
        'Could not reach your friend\'s Mac. Check the invite line and that remote co-op is still running.',
      );
    }
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}
    if (response.statusCode == 404 && path.endsWith('redeem-invite')) {
      throw const RemoteCoopJoinException(
        'That invite has expired or ended. Ask your friend to start remote co-op again and send a new line.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = json['error'] as String?;
      throw RemoteCoopJoinException(
        error != null && error.isNotEmpty
            ? 'The host refused: $error'
            : 'The invite address answered with HTTP ${response.statusCode}. Ask your friend for a new invite line.',
      );
    }
    return json;
  }
}

class RemoteCoopJoinException implements Exception {
  const RemoteCoopJoinException(this.message);

  final String message;

  @override
  String toString() => message;
}
