import 'package:flutter/material.dart';

import '../../../core/di/injection.dart';
import '../domain/access_admin.dart';

/// Trang Nhật ký (chỉ admin): 60 lần mở / thử sai gần nhất, mới nhất ở trên.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.lockId});

  final String lockId;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  late Future<List<LogEntry>> _logs = _load();

  Future<List<LogEntry>> _load() => sl<AccessAdmin>().readLogs(widget.lockId);

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime? t) =>
      t == null ? 'Không rõ giờ' : '${_two(t.day)}/${_two(t.month)}/${t.year} ${_two(t.hour)}:${_two(t.minute)}';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nhật ký'),
        actions: [
          IconButton(
            tooltip: 'Làm mới',
            onPressed: () => setState(() => _logs = _load()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: FutureBuilder<List<LogEntry>>(
        future: _logs,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(padding: const EdgeInsets.all(24), child: Text('Không đọc được nhật ký: ${snap.error}')),
            );
          }
          final logs = snap.data!;
          if (logs.isEmpty) return const Center(child: Text('Chưa có bản ghi nào'));
          return ListView.builder(
            itemCount: logs.length,
            itemBuilder: (context, i) {
              final e = logs[i];
              return ListTile(
                leading: Icon(
                  e.opened ? Icons.lock_open_rounded : Icons.warning_amber_rounded,
                  color: e.opened ? cs.primary : cs.error,
                ),
                title: Text(e.title),
                subtitle: Text(_fmt(e.time)),
              );
            },
          );
        },
      ),
    );
  }
}
