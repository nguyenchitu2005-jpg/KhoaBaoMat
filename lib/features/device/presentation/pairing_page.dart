import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import 'device_page.dart';
import 'pairing_cubit.dart';

/// Ghép đôi điện thoại với khoá lần đầu (chứng minh đang ở trong nhà + chống kẻ chen giữa).
class PairingPage extends StatelessWidget {
  const PairingPage({super.key, required this.device});

  final BluetoothDevice device;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<PairingCubit>(),
      child: BlocConsumer<PairingCubit, PairingState>(
        listener: (context, s) {
          if (s.step == PairingStep.done) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ghép đôi thành công')));
            Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(builder: (_) => DevicePage(device: device)),
            );
          }
        },
        builder: (context, s) => Scaffold(
          appBar: AppBar(title: const Text('Ghép đôi khoá')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (s.step == PairingStep.waitingForCode)
                _CodeCard(code: s.code!)
              else
                const _Instructions(),
              if (s.step == PairingStep.failed) ...[
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    leading: const Icon(Icons.error_outline_rounded),
                    title: Text(s.error ?? 'Ghép đôi thất bại'),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              if (s.step != PairingStep.waitingForCode)
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  onPressed: s.step == PairingStep.connecting
                      ? null
                      : () => context.read<PairingCubit>().start(device),
                  icon: s.step == PairingStep.connecting
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.link_rounded),
                  label: Text(switch (s.step) {
                    PairingStep.connecting => 'Đang kết nối…',
                    PairingStep.failed => 'Thử lại',
                    _ => 'Bắt đầu ghép đôi',
                  }),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Instructions extends StatelessWidget {
  const _Instructions();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget step(String n, String text) => ListTile(
          leading: CircleAvatar(child: Text(n)),
          title: Text(text),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Điện thoại này chưa ghép đôi với khoá', style: t.titleMedium),
            ),
            step('1', 'Ở trong nhà, GIỮ NÚT TRONG NHÀ khoảng 5 giây đến khi nghe tiếng bíp dài và đèn xanh nhấp nháy '
                '(hiện tại là nút BOOT trên mạch ESP32).'),
            step('2', 'Bấm "Bắt đầu ghép đôi" bên dưới trong vòng 60 giây.'),
            step('3', 'Gõ mã 6 số hiện trên màn hình vào bàn phím của khoá.'),
          ],
        ),
      ),
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text('Gõ mã này trên bàn phím của khoá', style: t.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FittedBox(
              child: Text(
                '${code.substring(0, 3)} ${code.substring(3)}',
                style: t.displayLarge?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 4),
              ),
            ),
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text('Gõ đủ 6 số là khoá tự xác nhận (bấm * để xoá). Còn tối đa 60 giây.',
                style: t.bodyMedium, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
