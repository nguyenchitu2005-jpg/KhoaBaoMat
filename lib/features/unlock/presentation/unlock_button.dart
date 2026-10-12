import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../domain/unlock_with_biometric.dart';
import 'unlock_bloc.dart';

/// Nút mở khoá. Tự đổi chữ theo từng bước và báo kết quả bằng SnackBar.
class UnlockButton extends StatelessWidget {
  const UnlockButton({super.key, required this.lockId, this.onUnlocked});

  final String lockId;
  final VoidCallback? onUnlocked;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<UnlockBloc>(),
      child: BlocConsumer<UnlockBloc, UnlockState>(
        listener: (context, state) {
          final message = switch (state) {
            UnlockSucceeded() => 'Đã mở cửa',
            UnlockFailed(:final message) => message,
            _ => null,
          };
          if (message != null) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
          }
          if (state is UnlockSucceeded) onUnlocked?.call();
        },
        builder: (context, state) {
          final busy = state is UnlockInProgress;
          final label = switch (state) {
            UnlockInProgress(step: UnlockStep.authenticating) => 'Đang xác thực…',
            UnlockInProgress(step: UnlockStep.sending) => 'Đang mở…',
            _ => 'Mở cửa',
          };
          return FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: busy ? null : () => context.read<UnlockBloc>().add(UnlockPressed(lockId)),
            icon: busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.lock_open_rounded),
            label: Text(label),
          );
        },
      ),
    );
  }
}
