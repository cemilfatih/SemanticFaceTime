import 'package:flutter/material.dart';
import '../services/storage_service.dart';

class SessionSummaryModal extends StatelessWidget {
  final Map<String, dynamic> summary;

  const SessionSummaryModal({super.key, required this.summary});

  static Future<void> show(BuildContext context, Map<String, dynamic> summary) {
    // Persist immediately when the modal is shown
    StorageService().save(SessionResult.fromSummary(summary));
    return showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      builder: (_) => SessionSummaryModal(summary: summary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final savings = (summary['savings_pct'] as num?)?.toDouble() ?? 0.0;
    final nbActual = (summary['nanoband_actual_mb'] as num?)?.toDouble() ?? 0.0;
    final nbTheory = (summary['nanoband_theoretical_mb'] as num?)?.toDouble() ?? 0.0;
    final stdActual = (summary['standard_actual_mb'] as num?)?.toDouble() ?? 0.0;
    final savedMb = (nbTheory - nbActual).clamp(0.0, double.infinity);
    final nbSecs = (summary['nanoband_seconds'] as num?)?.toDouble() ?? 0.0;
    final stdSecs = (summary['standard_seconds'] as num?)?.toDouble() ?? 0.0;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0F0F1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF1E1E35)),
        ),
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF00FF88), shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                const Text('SESSION COMPLETE',
                    style: TextStyle(
                      fontSize: 12, letterSpacing: 2,
                      color: Color(0xFF6868A0), fontFamily: 'monospace',
                    )),
              ],
            ),
            const SizedBox(height: 24),

            // NanoBand savings
            Text('${savings.toStringAsFixed(1)}%',
                style: const TextStyle(
                  fontSize: 64, fontWeight: FontWeight.w800,
                  color: Color(0xFF00FF88), height: 1, fontFamily: 'monospace',
                )),
            const SizedBox(height: 4),
            const Text('NANOBAND SAVINGS',
                style: TextStyle(
                  fontSize: 11, letterSpacing: 2,
                  color: Color(0xFF6868A0), fontFamily: 'monospace',
                )),
            const SizedBox(height: 8),
            Text('(NanoBand mode only — standard mode always = 0%)',
                style: const TextStyle(
                  fontSize: 10, color: Color(0xFF3A3A60), fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),

            // Stats grid
            Row(children: [
              _StatBox(label: 'NB ACTUAL', value: '${nbActual.toStringAsFixed(3)} MB', color: const Color(0xFF00FF88)),
              const SizedBox(width: 10),
              _StatBox(label: 'NB THEORETICAL', value: '${nbTheory.toStringAsFixed(3)} MB', color: const Color(0xFFFF375F)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              _StatBox(label: 'STANDARD SENT', value: '${stdActual.toStringAsFixed(3)} MB', color: const Color(0xFFFF9F0A)),
              const SizedBox(width: 10),
              _StatBox(label: 'NB TIME / STD TIME',
                  value: '${nbSecs.toStringAsFixed(0)}s / ${stdSecs.toStringAsFixed(0)}s',
                  color: const Color(0xFF6868A0)),
            ]),
            const SizedBox(height: 14),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0x1000FF88),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0x3000FF88)),
              ),
              child: Text(
                'NanoBand saved ${savedMb.toStringAsFixed(3)} MB vs 30fps JPEG',
                style: const TextStyle(
                  fontSize: 13, color: Color(0xFF00FF88), fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity, height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00FF88),
                  foregroundColor: const Color(0xFF08080F),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('CLOSE',
                    style: TextStyle(
                      fontWeight: FontWeight.w800, letterSpacing: 2, fontFamily: 'monospace',
                    )),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatBox({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF141422),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF1E1E35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                  fontSize: 9, letterSpacing: 1.2,
                  color: Color(0xFF6868A0), fontFamily: 'monospace',
                )),
            const SizedBox(height: 5),
            Text(value,
                style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700,
                  color: color, fontFamily: 'monospace',
                )),
          ],
        ),
      ),
    );
  }
}
