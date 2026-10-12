import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../domain/access_admin.dart';
import 'access_cubit.dart';

/// Trang Quản lý truy cập (chỉ admin): mã PIN, thẻ RFID, vân tay trên khoá.
class AccessPage extends StatelessWidget {
  const AccessPage({super.key, required this.lockId});

  final String lockId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => AccessCubit(sl<AccessAdmin>(), lockId)..load(),
      child: const _AccessView(),
    );
  }
}

class _AccessView extends StatelessWidget {
  const _AccessView();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AccessCubit, AccessState>(
      listenWhen: (a, b) => b.message != null && a.message != b.message,
      listener: (context, s) =>
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.message!))),
      builder: (context, s) {
        final cubit = context.read<AccessCubit>();
        final list = s.list;
        final t = Theme.of(context).textTheme;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Quản lý truy cập'),
            actions: [
              IconButton(
                tooltip: 'Làm mới',
                onPressed: s.busy ? null : cubit.load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (s.busy)
                Card(
                  child: ListTile(
                    leading: const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    title: Text(s.prompt ?? 'Đang xử lý…'),
                  ),
                ),
              if (list == null && !s.busy)
                const Card(child: ListTile(title: Text('Chưa đọc được danh sách – bấm Làm mới'))),
              if (list != null) ...[
                Text('Mã PIN', style: t.titleMedium),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.dialpad_rounded),
                    title: Text(list.hasPin ? 'Đã đặt' : 'Chưa đặt'),
                    subtitle: const Text('Gõ mã rồi bấm # trên bàn phím của khoá'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (list.hasPin)
                          TextButton(onPressed: s.busy ? null : () => cubit.setPin(''), child: const Text('Tắt')),
                        TextButton(
                          onPressed: s.busy
                              ? null
                              : () async {
                                  final pin = await showDialog<String>(context: context, builder: (_) => const _PinDialog());
                                  if (pin != null) await cubit.setPin(pin);
                                },
                          child: Text(list.hasPin ? 'Đổi' : 'Đặt'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Thẻ RFID (${list.cards.length}/20)', style: t.titleMedium),
                Card(
                  child: Column(
                    children: [
                      for (final c in list.cards)
                        ListTile(
                          leading: const Icon(Icons.credit_card_rounded),
                          title: Text('Thẻ ${c.index + 1}'),
                          subtitle: Text(c.uid),
                          trailing: IconButton(
                            tooltip: 'Xoá thẻ',
                            onPressed: s.busy ? null : () => cubit.deleteCard(c.index),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ),
                      ListTile(
                        leading: const Icon(Icons.add_rounded),
                        title: const Text('Thêm thẻ'),
                        enabled: !s.busy,
                        onTap: cubit.enrollCard,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text('Vân tay (${list.fingerIds.length}/32)', style: t.titleMedium),
                Card(
                  child: Column(
                    children: [
                      for (final id in list.fingerIds)
                        ListTile(
                          leading: const Icon(Icons.fingerprint_rounded),
                          title: Text('Vân tay #$id'),
                          trailing: IconButton(
                            tooltip: 'Xoá vân tay',
                            onPressed: s.busy ? null : () => cubit.deleteFinger(id),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ),
                      ListTile(
                        leading: const Icon(Icons.add_rounded),
                        title: const Text('Thêm vân tay'),
                        enabled: !s.busy,
                        onTap: cubit.enrollFinger,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Hộp thoại nhập mã PIN mới (4–8 chữ số). Trả về mã qua Navigator.pop.
class _PinDialog extends StatefulWidget {
  const _PinDialog();

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Mã PIN mới'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 8,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(helperText: '4–8 chữ số'),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
        FilledButton(
          onPressed: _controller.text.length >= 4 ? () => Navigator.pop(context, _controller.text) : null,
          child: const Text('Lưu'),
        ),
      ],
    );
  }
}
