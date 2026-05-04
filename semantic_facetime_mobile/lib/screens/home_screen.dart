import 'package:flutter/material.dart';
import '../services/storage_service.dart';
import 'call_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _storage = StorageService();
  List<SessionResult> _results = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _storage.getAll();
    if (mounted) setState(() => _results = r);
  }

  Future<void> _clearAll() async {
    await _storage.clear();
    if (mounted) setState(() => _results = []);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08080F),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _results.isEmpty ? _buildEmpty() : _buildList(),
            ),
            _buildStartButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('NANO',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 4,
                    color: Color(0xFF00FF88),
                    fontFamily: 'monospace',
                  )),
              const Text('BAND',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 4,
                    color: Color(0xFF6868A0),
                    fontFamily: 'monospace',
                  )),
              const Spacer(),
              if (_results.isNotEmpty)
                GestureDetector(
                  onTap: _clearAll,
                  child: const Text('CLEAR',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6868A0),
                        letterSpacing: 1,
                        fontFamily: 'monospace',
                      )),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Semantic Video Intelligence',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF3A3A60),
                letterSpacing: 1,
                fontFamily: 'monospace',
              )),
          const SizedBox(height: 24),
          if (_results.isNotEmpty) _buildSummaryCard(),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    final avgSavings = _results.map((r) => r.savingsPct).reduce((a, b) => a + b) / _results.length;
    final totalSaved = _results.map((r) => r.savedMb).reduce((a, b) => a + b);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E1E35)),
      ),
      child: Row(
        children: [
          _SummaryTile(
            label: 'AVG SAVINGS',
            value: '${avgSavings.toStringAsFixed(1)}%',
            color: const Color(0xFF00FF88),
          ),
          const SizedBox(width: 12),
          _SummaryTile(
            label: 'TOTAL SAVED',
            value: '${totalSaved.toStringAsFixed(2)} MB',
            color: const Color(0xFF00FF88),
          ),
          const SizedBox(width: 12),
          _SummaryTile(
            label: 'SESSIONS',
            value: '${_results.length}',
            color: const Color(0xFF6868A0),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('◉',
              style: TextStyle(fontSize: 48, color: Color(0xFF1E1E35))),
          SizedBox(height: 16),
          Text('No sessions yet',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF3A3A60),
                fontFamily: 'monospace',
              )),
          SizedBox(height: 4),
          Text('Start a call to measure savings',
              style: TextStyle(
                fontSize: 11,
                color: Color(0xFF2A2A50),
                fontFamily: 'monospace',
              )),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _ResultCard(result: _results[i]),
    );
  }

  Widget _buildStartButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: ElevatedButton(
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CallScreen()),
            );
            _load(); // refresh results when returning
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00FF88),
            foregroundColor: const Color(0xFF08080F),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: const Text('START CALL',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                fontFamily: 'monospace',
              )),
        ),
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _SummaryTile({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                fontSize: 9,
                color: Color(0xFF6868A0),
                letterSpacing: 1,
                fontFamily: 'monospace',
              )),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: color,
                fontFamily: 'monospace',
              )),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final SessionResult result;
  const _ResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final d = result.date;
    final label =
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1E1E35)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF6868A0),
                    fontFamily: 'monospace',
                  )),
              const SizedBox(height: 4),
              Text('NanoBand: ${result.nanobandSeconds.toStringAsFixed(0)}s  '
                  'Standard: ${result.standardSeconds.toStringAsFixed(0)}s',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF3A3A60),
                    fontFamily: 'monospace',
                  )),
            ],
          ),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${result.savingsPct.toStringAsFixed(1)}%',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF00FF88),
                    fontFamily: 'monospace',
                  )),
              Text('saved ${result.savedMb.toStringAsFixed(2)} MB',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF3A3A60),
                    fontFamily: 'monospace',
                  )),
            ],
          ),
        ],
      ),
    );
  }
}
