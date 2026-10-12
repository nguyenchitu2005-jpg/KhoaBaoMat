import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../core/ble/lock_protocol.dart';
import '../../../core/ble/secure_command_sender.dart';
import '../../../core/crypto/lock_crypto.dart';
import '../../../core/storage/lock_key_store.dart';
import '../../device/data/ble_lock_data_source.dart';

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

/// Những gì đang mở được khoá ngoài điện thoại: payload của lệnh LIST_ACCESS
/// `[có PIN 1B][mặt nạ vân tay 4B][số thẻ 1B][{chỉ số, độ dài, UID}…]`.
class AccessList extends Equatable {
  const AccessList({required this.hasPin, required this.fingerIds, required this.cards});

  factory AccessList.fromPayload(List<int> p) {
    if (p.length < 6) throw const FormatException('Danh sách truy cập không hợp lệ');
    final mask = LockCrypto.readU32(p, 1);
    final cards = <CardEntry>[];
    var offset = 6;
    for (var n = 0; n < p[5]; n++) {
      cards.add(CardEntry.fromBytes(p, offset));
      offset += 2 + p[offset + 1];
    }
    return AccessList(
      hasPin: p[0] == 1,
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

  @override
  List<Object?> get props => [hasPin, fingerIds, cards];
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
        (0, 4) => 'Mở bằng mã PIN',
        (0, 5) => 'Mở bằng nút trong nhà',
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
class AccessAdmin {
  AccessAdmin(this._keys, this._sender, this._ble);

  final LockKeyStore _keys;
  final SecureCommandSender _sender;
  final BleLockDataSource _ble;

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
