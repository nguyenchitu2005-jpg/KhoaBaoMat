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

  static String _guestLabel(DateTime? expiry) {
    if (expiry == null) return 'Chưa đặt';
    if (expiry.isBefore(DateTime.now())) return 'Đã hết hạn';
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Hết hạn ${two(expiry.hour)}:${two(expiry.minute)} ngày ${two(expiry.day)}/${two(expiry.month)}';
  }

  /// Hỏi mã rồi hỏi thời hạn.
  Future<void> _setGuestPin(BuildContext context, AccessCubit cubit) async {
    final pin = await showDialog<String>(context: context, builder: (_) => const _PinDialog(title: 'Mã khách mới'));
    if (pin == null || !context.mounted) return;
    final validFor = await showDialog<Duration>(context: context, builder: (_) => const _DurationDialog());
    if (validFor != null) await cubit.setGuestPin(pin, validFor);
  }

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
                Text('Mã khách', style: t.titleMedium),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.timelapse_rounded),
                    title: Text(_guestLabel(list.guestExpiry)),
                    subtitle: const Text('Mã PIN tạm cho khách, khoá tự bỏ khi hết hạn'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (list.guestExpiry != null)
                          TextButton(onPressed: s.busy ? null : () => cubit.setGuestPin(''), child: const Text('Xoá')),
                        TextButton(
                          onPressed: s.busy ? null : () => _setGuestPin(context, cubit),
                          child: Text(list.guestExpiry != null ? 'Đổi' : 'Đặt'),
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
                const SizedBox(height: 16),
                Text('Điện thoại (${s.phones.length}/8)', style: t.titleMedium),
                Card(
                  child: Column(
                    children: [
                      for (final p in s.phones)
                        ListTile(
                          leading: const Icon(Icons.smartphone_rounded),
                          title: Text('Điện thoại #${p.keyId}${p.isMe ? ' (máy này)' : ''}'),
                          subtitle: Text(p.isAdmin ? 'Admin' : 'Thành viên'),
                          trailing: p.isMe
                              ? null
                              : IconButton(
                                  tooltip: 'Thu hồi',
                                  onPressed: s.busy ? null : () => cubit.revokePhone(p.keyId),
                                  icon: const Icon(Icons.delete_outline_rounded),
                                ),
                        ),
                      const ListTile(
                        leading: Icon(Icons.info_outline_rounded),
                        title: Text('Thêm máy: giữ nút trong nhà 5 giây rồi ghép đôi trên máy mới'),
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

/// Hộp thoại nhập thời hạn của mã khách: một số kèm đơn vị phút hoặc giờ. Trả về Duration qua Navigator.pop.
class _DurationDialog extends StatefulWidget {
  const _DurationDialog();

  @override
  State<_DurationDialog> createState() => _DurationDialogState();
}

class _DurationDialogState extends State<_DurationDialog> {
  final _controller = TextEditingController(text: '60');
  bool _hours = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = int.tryParse(_controller.text) ?? 0;
    return AlertDialog(
      title: const Text('Có hiệu lực trong'),
      content: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 4,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('phút')),
              ButtonSegment(value: true, label: Text('giờ')),
            ],
            selected: {_hours},
            onSelectionChanged: (v) => setState(() => _hours = v.first),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
        FilledButton(
          onPressed: n > 0 ? () => Navigator.pop(context, _hours ? Duration(hours: n) : Duration(minutes: n)) : null,
          child: const Text('Lưu'),
        ),
      ],
    );
  }
}

/// Hộp thoại nhập mã PIN mới (4–8 chữ số). Trả về mã qua Navigator.pop.
class _PinDialog extends StatefulWidget {
  const _PinDialog({this.title = 'Mã PIN mới'});

  final String title;

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
      title: Text(widget.title),
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
