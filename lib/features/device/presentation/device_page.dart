import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../unlock/presentation/unlock_button.dart';
import '../domain/lock_status.dart';
import 'device_cubit.dart';

/// Màn hình 1 khoá: trạng thái, mở cửa (sinh trắc học), khoá ngay.
class DevicePage extends StatelessWidget {
  const DevicePage({super.key, required this.device});

  final BluetoothDevice device;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<DeviceCubit>()..connect(device),
      child: _DeviceView(device: device),
    );
  }
}

class _DeviceView extends StatelessWidget {
  const _DeviceView({required this.device});
  final BluetoothDevice device;

  @override
  Widget build(BuildContext context) {
    final name = device.platformName.isNotEmpty ? device.platformName : 'Khoabaomat';
    return BlocConsumer<DeviceCubit, DeviceState>(
      listenWhen: (a, b) => b.message != null && a.message != b.message,
      listener: (context, s) =>
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.message!))),
      builder: (context, s) {
        final cubit = context.read<DeviceCubit>();
        final connected = s.link == LinkState.connected;
        return Scaffold(
          appBar: AppBar(
            title: Text(name),
            actions: [
              IconButton(
                tooltip: 'Làm mới',
                onPressed: connected && !s.busy ? cubit.refresh : null,
                icon: const Icon(Icons.refresh_rounded),
              ),
              PopupMenuButton<String>(
                onSelected: (_) async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Bỏ ghép đôi?'),
                      content: const Text('Điện thoại này sẽ không mở được khoá nữa cho đến khi ghép đôi lại.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
                        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Bỏ ghép đôi')),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  await cubit.forget();
                  if (context.mounted) Navigator.of(context).pop();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'forget', child: Text('Bỏ ghép đôi trên máy này')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _LinkBanner(state: s, onRetry: () => cubit.connect(device)),
              const SizedBox(height: 16),
              _StatusCard(status: s.status),
              const SizedBox(height: 24),
              if (connected) ...[
                UnlockButton(lockId: device.remoteId.str, onUnlocked: cubit.refresh),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  onPressed: s.busy ? null : cubit.lockNow,
                  icon: const Icon(Icons.lock_rounded),
                  label: const Text('Khoá ngay'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _LinkBanner extends StatelessWidget {
  const _LinkBanner({required this.state, required this.onRetry});
  final DeviceState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, text, color) = switch (state.link) {
      LinkState.connecting => (Icons.bluetooth_searching_rounded, 'Đang kết nối…', cs.secondary),
      LinkState.connected => (Icons.bluetooth_connected_rounded, 'Đã kết nối', cs.primary),
      LinkState.disconnected => (Icons.bluetooth_disabled_rounded, 'Chưa kết nối', cs.error),
    };
    return Card(
      child: ListTile(
        leading: state.link == LinkState.connecting || state.busy
            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon, color: color),
        title: Text(text),
        trailing: state.link == LinkState.disconnected
            ? TextButton(onPressed: onRetry, child: const Text('Kết nối lại'))
            : null,
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});
  final LockStatus? status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final s = status;
    final unlocked = s?.unlocked ?? false;
    return Card(
      color: s == null ? null : (unlocked ? cs.tertiaryContainer : cs.primaryContainer),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              s == null ? Icons.help_outline_rounded : (unlocked ? Icons.lock_open_rounded : Icons.lock_rounded),
              size: 72,
            ),
            const SizedBox(height: 12),
            Text(s == null ? 'Chưa rõ trạng thái' : (unlocked ? 'Đang MỞ' : 'Đang KHOÁ'), style: t.headlineSmall),
            if (s != null) ...[
              const SizedBox(height: 8),
              Text('Khoá đã chạy ${_fmt(s.uptime)} · mở ${s.unlockCount} lần', style: t.bodyMedium),
              if (s.pairedPhones != null)
                Text('${s.pairedPhones} điện thoại đã ghép đôi', style: t.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    if (d.inHours > 0) return '${d.inHours} giờ ${d.inMinutes % 60} phút';
    if (d.inMinutes > 0) return '${d.inMinutes} phút';
    return '${d.inSeconds} giây';
  }
}
