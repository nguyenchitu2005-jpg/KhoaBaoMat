import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../core/ble/lock_protocol.dart';
import '../../../core/ble/secure_command_sender.dart';
import '../../../core/crypto/lock_crypto.dart';
import '../../../core/link/lock_link.dart';
import '../../../core/storage/lock_key_store.dart';
import '../../device/data/mqtt_lock_data_source.dart';

String _hex(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');

/// 1 thẻ RFID đã đăng ký trên khoá.
class CardEntry extends Equatable {
  const CardEntry(this.index, this.uid);

  /// `[chỉ số][độ dài UID][UID…]` bắt đầu tại [offset].
  factory CardEntry.fromBytes(List<int> p, [int offset = 0]) {
    if (offset + 2 > p.length || offset + 2 + p[offset + 1] > p.length) {
      throw const FormatException('Dữ liệu thẻ không hợp lệ');
    }
    return CardEntry(p[offset], _hex(p.sublist(offset + 2, offset + 2 + p[offset + 1])));
  }

  final int index; // vị trí trong bộ nhớ của khoá (0..19)
  final String uid; // dạng "04:A1:B2:C3"

  @override
  List<Object?> get props => [index, uid];
}

/// 1 điện thoại đã ghép đôi với khoá.
class PhoneEntry extends Equatable {
  const PhoneEntry({required this.keyId, required this.isAdmin, this.isMe = false});

  /// Payload LIST_PHONES: `[số điện thoại][{keyId, vai trò}…]`, vai trò 1 = admin. [myKeyId] = máy đang dùng.
  static List<PhoneEntry> listFromPayload(List<int> p, {int? myKeyId}) {
    if (p.isEmpty || p.length != 1 + 2 * p[0]) throw const FormatException('Danh sách điện thoại không hợp lệ');
    return [
      for (var i = 1; i < p.length; i += 2)
        PhoneEntry(keyId: p[i], isAdmin: p[i + 1] == 1, isMe: p[i] == myKeyId),
    ];
  }

  final int keyId;
  final bool isAdmin;
  final bool isMe;

  @override
  List<Object?> get props => [keyId, isAdmin, isMe];
}

/// Những gì đang mở được khoá ngoài điện thoại: payload của lệnh LIST_ACCESS
/// `[có PIN 1B][mặt nạ vân tay 4B][hạn mã khách 4B, 0 = không có][số thẻ 1B][{chỉ số, độ dài, UID}…]`.
class AccessList extends Equatable {
  const AccessList({required this.hasPin, required this.fingerIds, required this.cards, this.guestExpiry});

  factory AccessList.fromPayload(List<int> p) {
    if (p.length < 10) throw const FormatException('Danh sách truy cập không hợp lệ');
    final mask = LockCrypto.readU32(p, 1);
    final guest = LockCrypto.readU32(p, 5);
    final cards = <CardEntry>[];
    var offset = 10;
    for (var n = 0; n < p[9]; n++) {
      cards.add(CardEntry.fromBytes(p, offset));
      offset += 2 + p[offset + 1];
    }
    return AccessList(
      hasPin: p[0] == 1,
      guestExpiry: guest == 0 ? null : DateTime.fromMillisecondsSinceEpoch(guest * 1000),
      fingerIds: [
        for (var id = 1; id <= 32; id++)
          if ((mask >> (id - 1)) & 1 == 1) id,
      ],
      cards: cards,
    );
  }

  final bool hasPin;
  final List<int> fingerIds; // ID mẫu vân tay trong AS608 (1..32)
  final List<CardEntry> cards;
  final DateTime? guestExpiry; // giờ hết hạn của mã khách; null = chưa đặt

  @override
  List<Object?> get props => [hasPin, fingerIds, cards, guestExpiry];
}

/// 1 bản ghi nhật ký ra vào, 16 byte:
/// `[thời gian 4B little-endian][cờ][phương thức][ai][kết quả][dữ liệu thêm 8B]`.
class LogEntry extends Equatable {
  const LogEntry({required this.time, required this.method, required this.who, required this.result, this.extra = ''});

  factory LogEntry.fromBytes(List<int> r) {
    if (r.length != size) throw const FormatException('Bản ghi nhật ký không hợp lệ');
    final t = r[0] | (r[1] << 8) | (r[2] << 16) | (r[3] << 24);
    final extra = r.sublist(8).reversed.skipWhile((b) => b == 0).toList().reversed; // bỏ số 0 đệm ở cuối
    return LogEntry(
      // cờ bit 0 = giờ thật; nếu không thì khoá chưa được đồng bộ giờ lúc ghi
      time: r[4] & 1 == 1 ? DateTime.fromMillisecondsSinceEpoch(t * 1000) : null,
      method: r[5],
      who: r[6],
      result: r[7],
      extra: _hex(extra),
    );
  }

  static const size = 16;

  final DateTime? time; // null = không rõ giờ
  final int method; // 1 app, 2 thẻ, 3 vân tay, 4 PIN, 5 nút trong nhà
  final int who; // số điện thoại / chỉ số thẻ / ID vân tay
  final int result; // 0 mở, 1 thẻ hoặc vân tay lạ, 2 sai PIN, 3 khoá bàn phím
  final String extra; // UID của thẻ lạ

  bool get opened => result == 0;

  String get title => switch ((result, method)) {
        (0, 1) => 'Mở bằng app · điện thoại #$who',
        (0, 2) => 'Mở bằng thẻ ${who + 1}',
        (0, 3) => 'Mở bằng vân tay #$who',
        (0, 4) => who == 1 ? 'Mở bằng mã khách' : 'Mở bằng mã PIN',
        (0, 5) => 'Mở bằng nút trong nhà',
        (0, 6) => 'Mở từ xa qua internet · điện thoại #$who',
        (1, 2) => 'Thẻ lạ $extra',
        (1, _) => 'Vân tay lạ',
        (2, _) => 'Sai mã PIN',
        (3, _) => 'Sai PIN 5 lần – khoá bàn phím 5 phút',
        _ => 'Sự kiện $method/$result',
      };

  @override
  List<Object?> get props => [time, method, who, result, extra];
}

/// Các lệnh quản lý của admin: thẻ RFID, vân tay, mã PIN, nhật ký.
/// Khoá từ chối (0x03) nếu điện thoại không phải admin.
enum WifiState { notSet, connecting, connected, failed }

/// Trạng thái Wi-Fi của khoá. Payload WIFI_STATUS: `[trạng thái][sóng dBm][IP 4B][giờ NTP][độ dài tên][tên]`.
class WifiStatus extends Equatable {
  const WifiStatus({required this.state, this.ssid = '', this.rssi = 0, this.ip = '', this.timeSynced = false});

  factory WifiStatus.fromPayload(List<int> p) {
    if (p.length < 8 || p[0] >= WifiState.values.length || p.length != 8 + p[7]) {
      throw const FormatException('Trạng thái Wi-Fi không hợp lệ');
    }
    return WifiStatus(
      state: WifiState.values[p[0]],
      rssi: p[1] >= 128 ? p[1] - 256 : p[1],
      ip: p.sublist(2, 6).join('.'),
      timeSynced: p[6] == 1,
      ssid: utf8.decode(p.sublist(8), allowMalformed: true),
    );
  }

  final WifiState state;
  final String ssid; // mạng đã cài, rỗng = chưa cài
  final int rssi; // độ mạnh sóng (dBm), chỉ có khi đã kết nối
  final String ip;
  final bool timeSynced; // đã lấy giờ chuẩn qua NTP

  @override
  List<Object?> get props => [state, ssid, rssi, ip, timeSynced];
}

enum MqttLinkState { notSet, connecting, connected, error }

/// Khoá có đang vào máy chủ trung gian không. Payload MQTT_STATUS: `[trạng thái][độ dài host][host]`.
class MqttStatus extends Equatable {
  const MqttStatus({required this.state, this.host = ''});

  factory MqttStatus.fromPayload(List<int> p) {
    if (p.length < 2 || p[0] >= MqttLinkState.values.length || p.length != 2 + p[1]) {
      throw const FormatException('Trạng thái máy chủ trung gian không hợp lệ');
    }
    return MqttStatus(state: MqttLinkState.values[p[0]], host: utf8.decode(p.sublist(2), allowMalformed: true));
  }

  final MqttLinkState state;
  final String host; // máy chủ khoá đang dùng, rỗng = chưa cài

  @override
  List<Object?> get props => [state, host];
}

class AccessAdmin {
  AccessAdmin(this._keys, this._sender, this._ble);

  final LockKeyStore _keys;
  final SecureCommandSender _sender;
  final LockTransport _ble; // đường đang dùng (BLE / Wi-Fi): nhận gói tiến trình khi đăng ký vân tay

  Future<Uint8List> _send(
    String lockId,
    int cmd, {
    List<int> payload = const [],
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final cred = await _keys.read(lockId);
    if (cred == null) throw StateError('Điện thoại chưa ghép đôi với khoá này');
    return _sender.send(cred, cmd, payload: payload, timeout: timeout);
  }

  Future<AccessList> list(String lockId) async =>
      AccessList.fromPayload(await _send(lockId, LockCmd.listAccess));

  Future<List<PhoneEntry>> listPhones(String lockId) async => PhoneEntry.listFromPayload(
        await _send(lockId, LockCmd.listPhones),
        myKeyId: (await _keys.read(lockId))?.keyId,
      );

  /// Thu hồi 1 điện thoại: khoá xoá khoá AES của máy đó. Khoá từ chối nếu là chính máy này.
  Future<void> revokePhone(String lockId, int keyId) => _send(lockId, LockCmd.revokePhone, payload: [keyId]);

  /// Gửi Wi-Fi cho khoá (khoá chỉ dùng được mạng 2,4 GHz). [ssid] rỗng = quên Wi-Fi.
  /// Payload: `[độ dài tên][tên UTF-8][độ dài mật khẩu][mật khẩu]`. Đi qua kênh mã hoá như mọi lệnh khác.
  Future<void> setWifi(String lockId, String ssid, String password) {
    final name = utf8.encode(ssid);
    final pass = utf8.encode(password);
    if (name.length > 32 || pass.length > 63 || (pass.isNotEmpty && pass.length < 8) || (name.isEmpty && pass.isNotEmpty)) {
      throw ArgumentError('Tên mạng tối đa 32 ký tự; mật khẩu để trống (mạng mở) hoặc 8–63 ký tự');
    }
    return _send(lockId, LockCmd.setWifi, payload: [name.length, ...name, pass.length, ...pass]);
  }

  Future<WifiStatus> wifiStatus(String lockId) async => WifiStatus.fromPayload(await _send(lockId, LockCmd.wifiStatus));

  /// Gửi cấu hình máy chủ trung gian cho khoá (khoá tự vào máy chủ khi có Wi-Fi). null = tắt điều khiển từ xa.
  /// Payload: `[độ dài host][host][cổng 2B][độ dài user][user][độ dài mật khẩu][mật khẩu]`.
  /// Khoá từ chối lệnh này nếu gửi qua chính đường từ xa (nhập sai sẽ mất đường điều khiển khi đang ở xa).
  Future<void> setMqtt(String lockId, MqttSettings? s) {
    if (s == null) return _send(lockId, LockCmd.setMqtt, payload: [0]);
    final host = utf8.encode(s.host);
    final user = utf8.encode(s.user);
    final pass = utf8.encode(s.password);
    final payload = [host.length, ...host, s.port >> 8, s.port & 0xFF, user.length, ...user, pass.length, ...pass];
    if (host.isEmpty || [host, user, pass].any((f) => f.length > 64) || s.port < 1 || s.port > 65535 ||
        payload.length > 170) {
      throw ArgumentError('Địa chỉ máy chủ, tài khoản, mật khẩu mỗi thứ tối đa 64 ký tự (tổng tối đa 165); cổng 1–65535');
    }
    return _send(lockId, LockCmd.setMqtt, payload: payload);
  }

  Future<MqttStatus> mqttStatus(String lockId) async => MqttStatus.fromPayload(await _send(lockId, LockCmd.mqttStatus));

  /// Khoá chờ quẹt thẻ mới tối đa 15 giây.
  Future<CardEntry> enrollCard(String lockId) async => CardEntry.fromBytes(
      await _send(lockId, LockCmd.enrollRfid, timeout: const Duration(seconds: 20)));

  Future<void> deleteCard(String lockId, int index) => _send(lockId, LockCmd.deleteRfid, payload: [index]);

  /// Đặt tay 2 lần (mỗi lần khoá chờ tối đa 15 giây). [onProgress]: 1 = nhấc tay ra, 2 = đặt lại lần 2.
  /// Trả về ID vân tay mới.
  Future<int> enrollFinger(String lockId, {void Function(int step)? onProgress}) async {
    final sub = _ble.frames
        .where((f) => f.length == 3 && f[0] == FrameKind.progress && f[1] == LockCmd.enrollFinger)
        .listen((f) => onProgress?.call(f[2]));
    try {
      final reply = await _send(lockId, LockCmd.enrollFinger, timeout: const Duration(seconds: 40));
      if (reply.isEmpty) throw const FormatException('Phản hồi đăng ký vân tay không hợp lệ');
      return reply[0];
    } finally {
      await sub.cancel();
    }
  }

  Future<void> deleteFinger(String lockId, int id) => _send(lockId, LockCmd.deleteFinger, payload: [id]);

  /// [pin] 4–8 chữ số; chuỗi rỗng = tắt mở bằng PIN. Khoá chỉ lưu bản băm.
  Future<void> setPin(String lockId, String pin) {
    if (pin.isNotEmpty && !RegExp(r'^\d{4,8}$').hasMatch(pin)) {
      throw ArgumentError('Mã PIN phải gồm 4–8 chữ số');
    }
    return _send(lockId, LockCmd.setPin, payload: [pin.length, ...pin.codeUnits]);
  }

  /// Mã khách: PIN thứ hai, khoá tự bỏ sau [validFor]. [pin] rỗng = xoá mã khách.
  /// Payload: `[hết hạn unix 4B][độ dài][chữ số ASCII]`.
  Future<void> setGuestPin(String lockId, String pin, {Duration validFor = Duration.zero, DateTime? now}) {
    if (pin.isNotEmpty && (!RegExp(r'^\d{4,8}$').hasMatch(pin) || validFor <= Duration.zero)) {
      throw ArgumentError('Mã khách phải gồm 4–8 chữ số và có thời hạn');
    }
    final expiry = pin.isEmpty ? 0 : (now ?? DateTime.now()).add(validFor).millisecondsSinceEpoch ~/ 1000;
    return _send(lockId, LockCmd.setGuestPin, payload: [
      expiry >> 24, (expiry >> 16) & 0xFF, (expiry >> 8) & 0xFF, expiry & 0xFF,
      pin.length, ...pin.codeUnits,
    ]);
  }

  /// Đọc [count] bản ghi mới nhất, mới nhất đứng đầu.
  /// Phản hồi GET_LOGS: `[tổng 4B][bản ghi đầu tiên 4B][số bản ghi 1B][bản ghi 16B…]`, tối đa 12 bản ghi mỗi lần.
  Future<List<LogEntry>> readLogs(String lockId, {int count = 60}) async {
    final entries = <LogEntry>[];
    var from = 0xFFFFFFFF; // lần đầu hỏi quá cuối: chỉ để biết tổng số bản ghi
    while (true) {
      final p = await _send(lockId, LockCmd.getLogs,
          payload: [from >> 24, (from >> 16) & 0xFF, (from >> 8) & 0xFF, from & 0xFF]);
      if (p.length < 9 || p.length != 9 + p[8] * LogEntry.size) {
        throw const FormatException('Phản hồi nhật ký không hợp lệ');
      }
      final total = LockCrypto.readU32(p, 0);
      if (from == 0xFFFFFFFF) {
        if (total == 0) break;
        from = max(0, total - count);
        continue;
      }
      for (var i = 0; i < p[8]; i++) {
        entries.add(LogEntry.fromBytes(p.sublist(9 + i * LogEntry.size, 9 + (i + 1) * LogEntry.size)));
      }
      from = LockCrypto.readU32(p, 4) + p[8];
      if (p[8] == 0 || from >= total) break;
    }
    return entries.reversed.toList();
  }
}
