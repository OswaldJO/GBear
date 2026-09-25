import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Multiplexed GBTL tunnel over TCP (same framing as Mac [GBearSessionTunnel]).
class GBearSessionTunnel {
  static const magic = 0x4C544247; // GBTL LE
  static const channelControl = 1;
  static const channelVideo = 2;
  static const channelAudio = 3;
  static const channelInput = 4;

  Socket? _socket;
  final _buffer = BytesBuilder(copy: false);
  void Function(int channel, Uint8List payload)? onFrame;

  bool get isConnected => _socket != null;

  Future<void> connect(String host, int port) async {
    await disconnect();
    final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 8));
    _socket = socket;
    socket.listen(
      _onData,
      onError: (_) => disconnect(),
      onDone: () => disconnect(),
      cancelOnError: true,
    );
  }

  Future<void> disconnect() async {
    await _socket?.close();
    _socket = null;
    _buffer.clear();
  }

  void send(int channel, List<int> payload) {
    final socket = _socket;
    if (socket == null) return;
    final header = ByteData(9);
    header.setUint32(0, magic, Endian.little);
    header.setUint8(4, channel);
    header.setUint32(5, payload.length, Endian.little);
    socket.add(header.buffer.asUint8List());
    socket.add(payload);
  }

  void _onData(List<int> data) {
    _buffer.add(data);
    var bytes = _buffer.takeBytes();
    while (bytes.length >= 9) {
      final view = ByteData.sublistView(Uint8List.fromList(bytes));
      final m = view.getUint32(0, Endian.little);
      if (m != magic) {
        bytes = bytes.sublist(1);
        continue;
      }
      final channel = view.getUint8(4);
      final length = view.getUint32(5, Endian.little);
      final total = 9 + length;
      if (bytes.length < total) {
        _buffer.add(bytes);
        return;
      }
      final payload = Uint8List.fromList(bytes.sublist(9, total));
      onFrame?.call(channel, payload);
      bytes = bytes.sublist(total);
    }
    if (bytes.isNotEmpty) _buffer.add(bytes);
  }
}

/// Prefer LAN; when Mac control is unreachable, use coordinator ICE/TURN + tunnel.
class SessionTransportChooser {
  /// Returns true when HTTP control on [host]:[controlPort] responds.
  static Future<bool> canReachLan(String host, int controlPort) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await client.getUrl(Uri.parse('http://$host:$controlPort/gbear/v1/status'));
      final res = await req.close().timeout(const Duration(seconds: 2));
      await res.drain<void>();
      client.close(force: true);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static String describePath({required bool lanOk}) =>
      lanOk ? 'LAN direct (ports 28765–28769)' : 'Session tunnel / relay (coordinator)';
}
