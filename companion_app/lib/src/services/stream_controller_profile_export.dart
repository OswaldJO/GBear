import 'dart:convert';

import 'stream_controller_profile_store.dart';

/// JSON envelope for sharing controller mapping profiles between devices.
class StreamControllerProfileExport {
  static const formatVersion = 1;
  static const type = 'gbear_controller_profile';

  static Map<String, dynamic> envelope(StreamControllerProfile profile) {
    return {
      'formatVersion': formatVersion,
      'type': type,
      'exportedAtMs': DateTime.now().millisecondsSinceEpoch,
      'profile': profile.toJson(),
    };
  }

  static String encode(StreamControllerProfile profile) {
    return const JsonEncoder.withIndent('  ').convert(envelope(profile));
  }

  /// Parses export JSON; returns profile data without persisting.
  static StreamControllerProfile parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Expected a JSON object');
    }
    final map = Map<String, dynamic>.from(decoded);
    final typeValue = map['type'] as String?;
    if (typeValue != null && typeValue != StreamControllerProfileExport.type) {
      throw FormatException('Unsupported file type: $typeValue');
    }
    final version = map['formatVersion'] as int? ?? 1;
    if (version > formatVersion) {
      throw FormatException('Unsupported format version: $version');
    }
    final profileRaw = map['profile'];
    if (profileRaw is Map) {
      return _profileFromExport(Map<String, dynamic>.from(profileRaw));
    }
    // Allow bare profile object for hand-edited files.
    return _profileFromExport(map);
  }

  static StreamControllerProfile _profileFromExport(Map<String, dynamic> json) {
    final profile = StreamControllerProfile.fromJson(json);
    if (profile.bindings.isEmpty && profile.name == 'Profile' && profile.id.isEmpty) {
      throw const FormatException('No profile data found');
    }
    if (profile.id.isEmpty && profile.name.isEmpty) {
      throw const FormatException('Profile is missing a name');
    }
    return profile;
  }

  static String sanitizeFileName(String name) {
    final trimmed = name.trim().isEmpty ? 'profile' : name.trim();
    final safe = trimmed.replaceAll(RegExp(r'[^\w\-.]+'), '_');
    return safe.length > 48 ? safe.substring(0, 48) : safe;
  }
}
