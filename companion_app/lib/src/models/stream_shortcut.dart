import '../data/moonlight_key_codes.dart';

/// Named keyboard chord fired to the Mac during a stream (via `GBK1`).
class StreamShortcut {
  const StreamShortcut({
    required this.id,
    required this.name,
    required this.moonlightKeyCodes,
    required this.keyLabel,
  });

  final String id;
  final String name;
  final List<int> moonlightKeyCodes;
  final String keyLabel;

  /// macOS quit frontmost app (⌘Q).
  static const List<int> legacyCloseAppKeyCodes = [0x805B, 0x80A4, 0x801B];

  static StreamShortcut defaultCloseApp() {
    const keys = [
      MoonlightKeyOption(label: 'Command', windowsVk: 0x5B),
      MoonlightKeyOption(label: 'Q', windowsVk: 0x51),
    ];
    return StreamShortcut(
      id: 'close_app',
      name: 'Close app',
      moonlightKeyCodes: keys.map((k) => k.moonlightKeyCode).toList(),
      keyLabel: keys.map((k) => k.label).join(' + '),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'moonlightKeyCodes': moonlightKeyCodes,
        'keyLabel': keyLabel,
      };

  factory StreamShortcut.fromJson(Map<String, dynamic> json) {
    final codes = (json['moonlightKeyCodes'] as List?)
            ?.map((e) => (e as num).toInt())
            .where((c) => c != 0)
            .toList() ??
        const <int>[];
    final label = json['keyLabel'] as String? ?? _labelForCodes(codes);
    return StreamShortcut(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Shortcut',
      moonlightKeyCodes: codes,
      keyLabel: label,
    );
  }

  StreamShortcut copyWith({
    String? name,
    List<int>? moonlightKeyCodes,
    String? keyLabel,
  }) {
    return StreamShortcut(
      id: id,
      name: name ?? this.name,
      moonlightKeyCodes: moonlightKeyCodes ?? this.moonlightKeyCodes,
      keyLabel: keyLabel ?? this.keyLabel,
    );
  }

  static String _labelForCodes(List<int> codes) {
    if (codes.isEmpty) return 'No keys';
    return codes
        .map((c) => moonlightKeyByCode(c)?.label ?? 'Key')
        .join(' + ');
  }
}
