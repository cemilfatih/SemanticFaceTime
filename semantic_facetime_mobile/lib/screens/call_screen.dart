import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/camera_service.dart';
import '../services/websocket_service.dart';
import '../widgets/session_summary_modal.dart';

enum TransmitMode { nanoband, standard }

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  // ── Services ────────────────────────────────────────────────────
  final _cam = CameraService();
  final _ws = WebSocketService();

  // ── State ────────────────────────────────────────────────────────
  bool _camReady = false;
  bool _wsConnected = false;
  TransmitMode _mode = TransmitMode.nanoband;
  final Map<String, dynamic> _metrics = {};

  // ── Settings (editable via dialog) ───────────────────────────────
  //put ip here
  final _urlController = TextEditingController(text: 'ws://ip/ws/mobile');

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _requestPermissions();
    await _initCamera();
    await _connectWs();
    _startStream();
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera].request();
  }

  Future<void> _initCamera() async {
    try {
      await _cam.initialize();
      if (mounted) setState(() => _camReady = true);
    } catch (_) {
      // Camera init failed — preview will show error state
    }
  }

  Future<void> _connectWs() async {
    try {
      await _ws.connect(_urlController.text.trim());
      if (mounted) {
        setState(() => _wsConnected = true);
      }
      _listenWs();
    } catch (_) {
      if (mounted) {
        setState(() => _wsConnected = false);
      }
    }
  }

  void _listenWs() {
    _ws.messages.listen((msg) async {
      final type = msg['type'] as String?;

      if (type == 'REQUEST_ANCHOR') {
        _cam.pendingAnchorRequest = true;
      } else if (type == 'frame' || type == 'metrics') {
        final m = (msg['metrics'] ?? msg) as Map?;
        if (m != null && mounted) {
          setState(() {
            _metrics
              ..clear()
              ..addAll(Map<String, dynamic>.from(m));
          });
        }
      } else if (type == 'session_summary') {
        // 🎯 KESİN ÇÖZÜM: Gelen JSON'u güvenli bir şekilde haritalıyoruz.
        final rawSummary = msg['summary'];
        if (rawSummary != null && mounted) {
          final summary = Map<String, dynamic>.from(rawSummary as Map);

          // Modalı göster
          await SessionSummaryModal.show(context, summary);

          // Modal kapanınca Ana Ekrana dön
          if (mounted) Navigator.of(context).pop();
        }
      } else if (type == 'disconnected') {
        if (mounted) {
          setState(() => _wsConnected = false);
        }
      }
    });
  }

  void _startStream() {
    if (!_camReady) return;

    if (_mode == TransmitMode.nanoband) {
      _cam.startNanoBandStream(
        onLandmarks: (lms, w, h) {
          _ws.sendLandmarks(lms, w, h);
        },
        onAnchor: (jpeg, lms, w, h) {
          _ws.sendAnchorFrame(jpeg, lms, w, h);
        },
      );
    } else {
      _cam.startStandardStream(onFrame: (jpeg) => _ws.sendStandardFrame(jpeg));
    }
  }

  Future<void> _switchMode(TransmitMode newMode) async {
    if (newMode == _mode) return;
    await _cam.stopStream();
    setState(() => _mode = newMode);
    _startStream();
  }

  Future<void> _endCall() async {
    _ws.sendCallEnded();
    await _cam.stopStream();
    // Summary modal is shown by _listenWs when server replies
  }

  @override
  void dispose() {
    _cam.dispose();
    _ws.dispose();
    _urlController.dispose();
    super.dispose();
  }

  // ── UI ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08080F),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildCameraPreview()),
            _buildBottomPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final isNano = _mode == TransmitMode.nanoband;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0F0F1A),
        border: Border(bottom: BorderSide(color: Color(0xFF1E1E35))),
      ),
      child: Row(
        children: [
          // Logo
          const Text(
            'NANO',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
              color: Color(0xFF00FF88),
              fontFamily: 'monospace',
            ),
          ),
          const Text(
            'BAND',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w300,
              letterSpacing: 3,
              color: Color(0xFF6868A0),
              fontFamily: 'monospace',
            ),
          ),
          const Spacer(),
          // Mode badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isNano
                  ? const Color(0xFF00FF88).withAlpha(20)
                  : const Color(0xFFFF9F0A).withAlpha(20),
              border: Border.all(
                color: isNano
                    ? const Color(0xFF00FF88).withAlpha(80)
                    : const Color(0xFFFF9F0A).withAlpha(80),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              isNano ? '◆ NANOBAND' : '▲ STANDARD',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
                fontFamily: 'monospace',
                color: isNano
                    ? const Color(0xFF00FF88)
                    : const Color(0xFFFF9F0A),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // WS status dot
          _WsDot(connected: _wsConnected),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (!_camReady || _cam.controller == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF00FF88), strokeWidth: 2),
            SizedBox(height: 16),
            Text(
              'Initializing camera…',
              style: TextStyle(
                color: Color(0xFF6868A0),
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview
        ClipRect(
          child: OverflowBox(
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _cam.controller!.value.previewSize?.height ?? 480,
                height: _cam.controller!.value.previewSize?.width ?? 640,
                child: CameraPreview(_cam.controller!),
              ),
            ),
          ),
        ),

        // Metrics overlay (top-right)
        if (_metrics.isNotEmpty)
          Positioned(
            top: 14,
            right: 14,
            child: _MetricsOverlay(metrics: _metrics),
          ),

        // Status overlay (bottom-left)
        Positioned(
          bottom: 14,
          left: 14,
          child: _StatusChip(status: _metrics['status'] as String? ?? ''),
        ),
      ],
    );
  }

  Widget _buildBottomPanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: const BoxDecoration(
        color: Color(0xFF0F0F1A),
        border: Border(top: BorderSide(color: Color(0xFF1E1E35))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mode toggle
          _ModeToggle(current: _mode, onChanged: _switchMode),
          const SizedBox(height: 16),
          // Action row
          Row(
            children: [
              // Server URL button
              _IconBtn(
                icon: Icons.settings_ethernet,
                onTap: _showUrlDialog,
                color: const Color(0xFF6868A0),
              ),
              const Spacer(),
              // End call
              GestureDetector(
                onTap: _endCall,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF375F),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFF375F).withAlpha(80),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.call_end,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
              const Spacer(),
              // Reconnect button
              _IconBtn(
                icon: Icons.refresh,
                onTap: () async {
                  await _ws.disconnect();
                  if (mounted) setState(() => _wsConnected = false);
                  await _connectWs();
                },
                color: const Color(0xFF6868A0),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showUrlDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141422),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'SERVER URL',
          style: TextStyle(
            fontSize: 13,
            letterSpacing: 2,
            color: Color(0xFF6868A0),
            fontFamily: 'monospace',
          ),
        ),
        content: TextField(
          controller: _urlController,
          style: const TextStyle(
            color: Color(0xFF00FF88),
            fontFamily: 'monospace',
            fontSize: 14,
          ),
          decoration: const InputDecoration(
            hintText: 'ws://192.168.x.x:8000/ws/mobile',
            hintStyle: TextStyle(color: Color(0xFF3A3A60)),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF1E1E35)),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF00FF88)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'CANCEL',
              style: TextStyle(
                color: Color(0xFF6868A0),
                fontFamily: 'monospace',
              ),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _ws.disconnect();
              await _connectWs();
            },
            child: const Text(
              'CONNECT',
              style: TextStyle(
                color: Color(0xFF00FF88),
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Sub-widgets ────────────────────────────────────────────────────────

class _WsDot extends StatelessWidget {
  final bool connected;
  const _WsDot({required this.connected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: connected ? const Color(0xFF00FF88) : const Color(0xFFFF375F),
        boxShadow: [
          BoxShadow(
            color:
                (connected ? const Color(0xFF00FF88) : const Color(0xFFFF375F))
                    .withAlpha(100),
            blurRadius: 6,
          ),
        ],
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final TransmitMode current;
  final ValueChanged<TransmitMode> onChanged;
  const _ModeToggle({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF141422),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1E1E35)),
      ),
      child: Row(
        children: [
          _Tab(
            label: '◆  NANOBAND',
            active: current == TransmitMode.nanoband,
            activeColor: const Color(0xFF00FF88),
            onTap: () => onChanged(TransmitMode.nanoband),
          ),
          _Tab(
            label: '▲  STANDARD',
            active: current == TransmitMode.standard,
            activeColor: const Color(0xFFFF9F0A),
            onTap: () => onChanged(TransmitMode.standard),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  const _Tab({
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: active ? activeColor.withAlpha(30) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: active
                ? Border.all(color: activeColor.withAlpha(100))
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              fontFamily: 'monospace',
              color: active ? activeColor : const Color(0xFF6868A0),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricsOverlay extends StatelessWidget {
  final Map<String, dynamic> metrics;
  const _MetricsOverlay({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final savings = (metrics['savings_pct'] as num?)?.toDouble() ?? 0.0;
    final fps = metrics['current_fps'];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(160),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF1E1E35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${savings.toStringAsFixed(1)}% SAVED',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Color(0xFF00FF88),
              fontFamily: 'monospace',
            ),
          ),
          if (fps != null)
            Text(
              '$fps FPS anchor',
              style: const TextStyle(
                fontSize: 10,
                color: Color(0xFF6868A0),
                fontFamily: 'monospace',
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  Color get _color {
    switch (status) {
      case 'STABLE':
        return const Color(0xFF00FF88);
      case 'TALKING':
        return const Color(0xFFFF9F0A);
      case 'HEAD MOVING':
        return const Color(0xFFFF375F);
      case 'MOUTH TRIGGER':
        return const Color(0xFFBF5AF2);
      default:
        return const Color(0xFF6868A0);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (status.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(160),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _color.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: _color),
          ),
          const SizedBox(width: 6),
          Text(
            status,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _color,
              letterSpacing: 1,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  const _IconBtn({
    required this.icon,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: const Color(0xFF141422),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF1E1E35)),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }
}
