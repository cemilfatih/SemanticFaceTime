import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SessionResult {
  final DateTime date;
  final double nanobandActualMb;
  final double nanobandTheoreticalMb;
  final double savingsPct;
  final double nanobandSeconds;
  final double standardSeconds;

  const SessionResult({
    required this.date,
    required this.nanobandActualMb,
    required this.nanobandTheoreticalMb,
    required this.savingsPct,
    required this.nanobandSeconds,
    required this.standardSeconds,
  });

  double get savedMb => (nanobandTheoreticalMb - nanobandActualMb).clamp(0, double.infinity);

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'nanobandActualMb': nanobandActualMb,
        'nanobandTheoreticalMb': nanobandTheoreticalMb,
        'savingsPct': savingsPct,
        'nanobandSeconds': nanobandSeconds,
        'standardSeconds': standardSeconds,
      };

  factory SessionResult.fromJson(Map<String, dynamic> j) => SessionResult(
        date: DateTime.parse(j['date'] as String),
        nanobandActualMb: (j['nanobandActualMb'] as num).toDouble(),
        nanobandTheoreticalMb: (j['nanobandTheoreticalMb'] as num).toDouble(),
        savingsPct: (j['savingsPct'] as num).toDouble(),
        nanobandSeconds: (j['nanobandSeconds'] as num?)?.toDouble() ?? 0,
        standardSeconds: (j['standardSeconds'] as num?)?.toDouble() ?? 0,
      );

  factory SessionResult.fromSummary(Map<String, dynamic> summary) => SessionResult(
        date: DateTime.now(),
        nanobandActualMb: (summary['nanoband_actual_mb'] as num?)?.toDouble() ?? 0,
        nanobandTheoreticalMb: (summary['nanoband_theoretical_mb'] as num?)?.toDouble() ?? 0,
        savingsPct: (summary['savings_pct'] as num?)?.toDouble() ?? 0,
        nanobandSeconds: (summary['nanoband_seconds'] as num?)?.toDouble() ?? 0,
        standardSeconds: (summary['standard_seconds'] as num?)?.toDouble() ?? 0,
      );
}

class StorageService {
  static const _key = 'nanoband_results';

  Future<void> save(SessionResult result) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getAll();
    existing.insert(0, result); // newest first
    final encoded = existing.map((r) => jsonEncode(r.toJson())).toList();
    await prefs.setStringList(_key, encoded);
  }

  Future<List<SessionResult>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return raw
        .map((s) => SessionResult.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
