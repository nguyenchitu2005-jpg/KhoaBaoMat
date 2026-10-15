import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../device/data/lan_lock_data_source.dart';
import '../../device/data/mqtt_lock_data_source.dart';
import '../../face/data/face_auth_service.dart';
import '../domain/access_admin.dart';
import 'access_cubit.dart';

/// Camera + ML Kit nhận diện khuôn mặt chỉ chạy trên Android/iOS (Windows vẫn dùng sinh trắc học của máy).
bool get _faceSupported =>
    defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// Trang Quản lý truy cập (chỉ admin): mã PIN, thẻ RFID, vân tay, điện thoại, Wi-Fi của khoá,
/// và khuôn mặt dùng để xác nhận trên app.
class AccessPage extends StatelessWidget {
  const AccessPage({super.key, required this.lockId});

  final String lockId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => AccessCubit(sl<AccessAdmin>(), lockId, sl<LanLockDataSource>(), sl<MqttLockDataSource>())..load(),
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

  static String _wifiTitle(WifiStatus? w) => switch (w?.state) {
        null => 'Khoá chưa hỗ trợ Wi-Fi',
        WifiState.notSet => 'Chưa cài Wi-Fi',
        WifiState.connecting => 'Đang kết nối "${w?.ssid}"…',
        WifiState.connected => 'Đã kết nối "${w?.ssid}"',
        WifiState.failed => 'Không vào được "${w?.ssid}"',
      };

  static String _remoteTitle(MqttStatus? m) => switch (m?.state) {
        null => 'Khoá chưa hỗ trợ điều khiển từ xa',
        MqttLinkState.notSet => 'Chưa cài máy chủ trung gian',
        MqttLinkState.connecting => 'Khoá đang vào máy chủ…',
        MqttLinkState.connected => 'Khoá đang online – mở được từ xa',
        MqttLinkState.error => 'Khoá không vào được máy chủ ${m?.host}',
      };

  static String _wifiSubtitle(WifiStatus? w) => switch (w?.state) {
        null => 'Nạp firmware mới cho khoá để dùng Wi-Fi',
        WifiState.notSet => 'Khoá dùng Wi-Fi để lấy giờ chuẩn. Chỉ mạng 2,4 GHz',
        WifiState.connecting => 'Chờ vài giây rồi bấm Làm mới',
        WifiState.connected =>
          'IP ${w!.ip} · sóng ${w.rssi} dBm · ${w.timeSynced ? 'giờ đã đồng bộ' : 'đang lấy giờ'}',
        WifiState.failed => 'Kiểm tra mật khẩu; khoá chỉ dùng được Wi-Fi 2,4 GHz',
      };

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
                if (_faceSupported) ...[
                  const SizedBox(height: 16),
                  Text('Mở khoá bằng khuôn mặt', style: t.titleMedium),
                  const _FaceSection(),
                ],
                const SizedBox(height: 16),
                Text('Wi-Fi của khoá', style: t.titleMedium),
                Card(
                  child: ListTile(
                    leading: Icon(s.wifi?.state == WifiState.connected ? Icons.wifi_rounded : Icons.wifi_off_rounded),
                    title: Text(_wifiTitle(s.wifi)),
                    subtitle: Text(_wifiSubtitle(s.wifi)),
                    trailing: s.wifi == null
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (s.wifi!.state != WifiState.notSet)
                                TextButton(onPressed: s.busy ? null : () => cubit.setWifi('', ''), child: const Text('Quên')),
                              TextButton(
                                onPressed: s.busy
                                    ? null
                                    : () async {
                                        final w = await showDialog<(String, String)>(
                                            context: context, builder: (_) => _WifiDialog(ssid: s.wifi!.ssid));
                                        if (w != null) await cubit.setWifi(w.$1, w.$2);
                                      },
                                child: Text(s.wifi!.state == WifiState.notSet ? 'Cài' : 'Đổi'),
                              ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Điều khiển từ xa', style: t.titleMedium),
                Card(
                  child: ListTile(
                    leading: Icon(s.mqtt?.state == MqttLinkState.connected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded),
                    title: Text(_remoteTitle(s.mqtt)),
                    subtitle: Text(s.remote == null
                        ? 'Mở cửa khi ở xa nhà qua máy chủ trung gian MQTT (vd. HiveMQ Cloud). Khoá cần có Wi-Fi'
                        : 'Máy này dùng ${s.remote!.host}'),
                    isThreeLine: true,
                    trailing: s.mqtt == null
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (s.mqtt!.state != MqttLinkState.notSet || s.remote != null)
                                TextButton(onPressed: s.busy ? null : () => cubit.setRemote(null), child: const Text('Tắt')),
                              TextButton(
                                onPressed: s.busy
                                    ? null
                                    : () async {
                                        final m = await showDialog<MqttSettings>(
                                            context: context, builder: (_) => _MqttDialog(initial: s.remote));
                                        if (m != null) await cubit.setRemote(m);
                                      },
                                child: Text(s.remote == null ? 'Cài' : 'Đổi'),
                              ),
                            ],
                          ),
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

/// Hộp thoại nhập Wi-Fi cho khoá. Trả về (tên mạng, mật khẩu) qua Navigator.pop.
class _WifiDialog extends StatefulWidget {
  const _WifiDialog({required this.ssid});

  final String ssid; // mạng đang cài, điền sẵn để đổi mật khẩu cho nhanh

  @override
  State<_WifiDialog> createState() => _WifiDialogState();
}

class _WifiDialogState extends State<_WifiDialog> {
  late final _ssid = TextEditingController(text: widget.ssid);
  final _pass = TextEditingController();
  bool _showPass = false;
  String? _error;

  @override
  void dispose() {
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _submit() {
    final ssid = _ssid.text; // không cắt khoảng trắng: tên mạng có thể có thật
    final pass = _pass.text;
    if (ssid.isEmpty) return setState(() => _error = 'Nhập tên mạng');
    if (utf8.encode(ssid).length > 32) return setState(() => _error = 'Tên mạng quá dài (tối đa 32 ký tự)');
    if (pass.isNotEmpty && (pass.length < 8 || utf8.encode(pass).length > 63)) {
      return setState(() => _error = 'Mật khẩu Wi-Fi gồm 8–63 ký tự (để trống nếu mạng không có mật khẩu)');
    }
    Navigator.pop(context, (ssid, pass));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Wi-Fi cho khoá'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _ssid,
            autofocus: widget.ssid.isEmpty,
            decoration: const InputDecoration(labelText: 'Tên mạng (SSID)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pass,
            autofocus: widget.ssid.isNotEmpty,
            obscureText: !_showPass,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Mật khẩu',
              errorText: _error,
              errorMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: _showPass ? 'Ẩn mật khẩu' : 'Hiện mật khẩu',
                onPressed: () => setState(() => _showPass = !_showPass),
                icon: Icon(_showPass ? Icons.visibility_off_rounded : Icons.visibility_rounded),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Khoá chỉ dùng được Wi-Fi 2,4 GHz. Mật khẩu được mã hoá khi gửi qua Bluetooth.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
        FilledButton(onPressed: _submit, child: const Text('Gửi cho khoá')),
      ],
    );
  }
}

/// Khuôn mặt dùng để xác nhận trên app (mở cửa, vào trang quản lý). Lưu trên điện thoại, không gửi cho khoá.
class _FaceSection extends StatefulWidget {
  const _FaceSection();

  @override
  State<_FaceSection> createState() => _FaceSectionState();
}

class _FaceSectionState extends State<_FaceSection> {
  final _face = sl<FaceAuthService>();
  late Future<bool> _enrolled = _face.enrolled;
  bool _busy = false;

  Future<void> _run(Future<String?> Function() action, String done) async {
    setState(() => _busy = true);
    final error = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _enrolled = _face.enrolled;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? done)));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _enrolled,
      builder: (context, snap) {
        final enrolled = snap.data ?? false;
        return Card(
          child: ListTile(
            leading: const Icon(Icons.face_rounded),
            title: Text(enrolled ? 'Đã đăng ký' : 'Chưa đăng ký'),
            subtitle: Text(enrolled
                ? 'Mở cửa và vào trang này sẽ quét khuôn mặt'
                : 'Đang dùng vân tay / khuôn mặt của máy để xác nhận'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (enrolled)
                  TextButton(
                    onPressed: _busy ? null : () => _run(_face.remove, 'Đã xoá khuôn mặt'),
                    child: const Text('Xoá'),
                  ),
                TextButton(
                  onPressed: _busy ? null : () => _run(_face.enroll, 'Đã đăng ký khuôn mặt'),
                  child: Text(enrolled ? 'Đăng ký lại' : 'Đăng ký'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Hộp thoại nhập máy chủ trung gian MQTT (TLS). Trả về MqttSettings qua Navigator.pop.
class _MqttDialog extends StatefulWidget {
  const _MqttDialog({this.initial});

  final MqttSettings? initial;

  @override
  State<_MqttDialog> createState() => _MqttDialogState();
}

class _MqttDialogState extends State<_MqttDialog> {
  late final _host = TextEditingController(text: widget.initial?.host ?? '');
  late final _port = TextEditingController(text: '${widget.initial?.port ?? 8883}');
  late final _user = TextEditingController(text: widget.initial?.user ?? '');
  final _pass = TextEditingController();
  bool _showPass = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    // Dán cả URL (mqtts://host:8883) cũng được: chỉ lấy phần tên máy chủ
    final host = _host.text.trim().replaceFirst(RegExp(r'^\w+://'), '').split(RegExp('[:/]')).first;
    final port = int.tryParse(_port.text.trim());
    final pass = _pass.text.isEmpty ? (widget.initial?.password ?? '') : _pass.text;
    if (host.isEmpty || !host.contains('.')) return setState(() => _error = 'Nhập địa chỉ máy chủ, vd. abc123.s1.eu.hivemq.cloud');
    if (port == null || port < 1 || port > 65535) return setState(() => _error = 'Cổng không hợp lệ (HiveMQ Cloud dùng 8883)');
    if (_user.text.trim().isEmpty || pass.isEmpty) return setState(() => _error = 'Nhập tài khoản và mật khẩu của máy chủ');
    Navigator.pop(context, MqttSettings(host: host, port: port, user: _user.text.trim(), password: pass));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Máy chủ trung gian'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Địa chỉ (Host)', hintText: 'abc123.s1.eu.hivemq.cloud'),
            ),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Cổng TLS'),
            ),
            TextField(controller: _user, decoration: const InputDecoration(labelText: 'Tài khoản (username)')),
            TextField(
              controller: _pass,
              obscureText: !_showPass,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: widget.initial == null ? 'Mật khẩu' : 'Mật khẩu (để trống = giữ như cũ)',
                errorText: _error,
                errorMaxLines: 3,
                suffixIcon: IconButton(
                  tooltip: _showPass ? 'Ẩn mật khẩu' : 'Hiện mật khẩu',
                  onPressed: () => setState(() => _showPass = !_showPass),
                  icon: Icon(_showPass ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Máy chủ chỉ chuyển gói đã mã hoá, không tự mở cửa được. '
              'Phải cài khi đang ở nhà (qua Wi-Fi trong nhà hoặc Bluetooth).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
        FilledButton(onPressed: _submit, child: const Text('Lưu và gửi cho khoá')),
      ],
    );
  }
}
