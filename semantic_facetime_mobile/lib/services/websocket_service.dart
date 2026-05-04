import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

class WebSocketService {
  WebSocketChannel? _channel;
  final _msgCtrl = StreamController<Map<String, dynamic>>.broadcast();
  bool _connected = false;

  Stream<Map<String, dynamic>> get messages => _msgCtrl.stream;
  bool get isConnected => _connected;

  Future<void> connect(String url) async {
    _channel = WebSocketChannel.connect(Uri.parse(url));
    _connected = true;

    _channel!.stream.listen(
      (raw) {
        try {
          final msg = jsonDecode(raw as String) as Map<String, dynamic>;
          _msgCtrl.add(msg);
        } catch (_) {}
      },
      onDone: () {
        _connected = false;
        _msgCtrl.add({'type': 'disconnected'});
      },
      onError: (e) {
        _connected = false;
        _msgCtrl.add({'type': 'error', 'message': e.toString()});
      },
    );
  }

  // ── NanoBand mode ────────────────────────────────────────────────

  void sendLandmarks(
    List<List<double>> landmarks,
    int width,
    int height,
  ) {
    _send({
      'type': 'landmarks',
      'data': landmarks,
      'width': width,
      'height': height,
    });
  }

  void sendAnchorFrame(
    Uint8List jpeg,
    List<List<double>> landmarks,
    int width,
    int height,
  ) {
    _send({
      'type': 'anchor_frame',
      'data': base64Encode(jpeg),
      'landmarks': landmarks,
      'width': width,
      'height': height,
    });
  }

  // ── Standard mode ────────────────────────────────────────────────

  void sendStandardFrame(Uint8List jpeg) {
    _send({'type': 'standard_frame', 'data': base64Encode(jpeg)});
  }

  // ── Session control ──────────────────────────────────────────────

  void sendCallEnded() => _send({'type': 'call_ended'});

  Future<void> disconnect() async {
    _connected = false;
    await _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
  }

  void dispose() {
    disconnect();
    _msgCtrl.close();
  }

  void _send(Map<String, dynamic> payload) {
    if (!_connected || _channel == null) return;
    _channel!.sink.add(jsonEncode(payload));
  }
}
