import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/storage/lock_key_store.dart';
import 'device_page.dart';
import 'pairing_page.dart';
import 'scan_cubit.dart';

/// Màn hình đầu: tìm các khoá Khoabaomat ở gần.
class ScanPage extends StatelessWidget {
  const ScanPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<ScanCubit>(),
      child: const _ScanView(),
    );
  }
}

class _ScanView extends StatelessWidget {
  const _ScanView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tìm khoá')),
      body: BlocConsumer<ScanCubit, ScanState>(
        listenWhen: (a, b) => b.error != null && a.error != b.error,
        listener: (context, s) =>
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.error!))),
        builder: (context, s) {
          if (s.results.isEmpty) {
            return _EmptyHint(scanning: s.scanning);
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: s.results.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final r = s.results[i];
              final name = r.device.platformName.isNotEmpty ? r.device.platformName : 'Khoabaomat';
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.lock_outline_rounded, size: 32),
                  title: Text(name),
                  subtitle: Text(r.device.remoteId.str),
                  trailing: _Rssi(r.rssi),
                  onTap: () async {
                    await context.read<ScanCubit>().stop();
                    final paired = await sl<LockKeyStore>().read(r.device.remoteId.str) != null;
                    if (!context.mounted) return;
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => paired ? DevicePage(device: r.device) : PairingPage(device: r.device),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: BlocBuilder<ScanCubit, ScanState>(
        builder: (context, s) => FloatingActionButton.extended(
          onPressed: s.scanning ? null : () => context.read<ScanCubit>().start(),
          icon: s.scanning
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.bluetooth_searching_rounded),
          label: Text(s.scanning ? 'Đang tìm…' : 'Tìm khoá'),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.scanning});
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sensor_door_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(scanning ? 'Đang tìm khoá ở gần…' : 'Chưa tìm thấy khoá nào', style: t.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Bật Bluetooth, đứng gần cửa rồi bấm "Tìm khoá".',
              textAlign: TextAlign.center,
              style: t.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _Rssi extends StatelessWidget {
  const _Rssi(this.rssi);
  final int rssi;

  @override
  Widget build(BuildContext context) {
    final icon = rssi > -60
        ? Icons.signal_cellular_alt_rounded
        : rssi > -80
            ? Icons.signal_cellular_alt_2_bar_rounded
            : Icons.signal_cellular_alt_1_bar_rounded;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [Icon(icon), Text('$rssi dBm', style: Theme.of(context).textTheme.labelSmall)],
    );
  }
}
