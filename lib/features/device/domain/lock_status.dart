import 'package:equatable/equatable.dart';

import '../../../core/ble/lock_protocol.dart';
import '../../../core/ble/secure_command_sender.dart';
import '../../../core/crypto/lock_crypto.dart';
import '../../../core/storage/lock_key_store.dart';

/// Trạng thái khoá trả về từ lệnh STATUS:
/// payload `[relayOn 1B][uptime giây 4B][số lần mở 4B][số điện thoại 1B][đang ghép đôi 1B][vai trò 1B][bàn phím bị khoá 1B]`.
class LockStatus extends Equatable {
  const LockStatus({
    required this.unlocked,
    required this.uptime,
    required this.unlockCount,
    this.pairedPhones,
    this.pairingMode = false,
    this.isAdmin = false,
    this.keypadLocked = false,
  });

  factory LockStatus.fromPayload(List<int> p) {
    if (p.length < 9) throw const FormatException('Gói trạng thái không hợp lệ');
    return LockStatus(
      unlocked: p[0] == 1,
      uptime: Duration(seconds: LockCrypto.readU32(p, 1)),
      unlockCount: LockCrypto.readU32(p, 5),
      pairedPhones: p.length >= 11 ? p[9] : null, // firmware giai đoạn 2 gửi thêm 2 byte
      pairingMode: p.length >= 11 && p[10] == 1,
      isAdmin: p.length >= 13 && p[11] == 1, // firmware giai đoạn 3 gửi thêm 2 byte; vai trò 1 = admin
      keypadLocked: p.length >= 13 && p[12] == 1,
    );
  }

  final bool unlocked; // relay đang đóng → chốt đang mở
  final Duration uptime; // thời gian ESP32 chạy từ lần khởi động gần nhất
  final int unlockCount; // số lần mở từ lần khởi động gần nhất
  final int? pairedPhones; // số điện thoại đã ghép đôi
  final bool pairingMode; // khoá đang mở chế độ ghép đôi
  final bool isAdmin; // điện thoại này là admin (được quản lý thẻ / vân tay / PIN, xem nhật ký)
  final bool keypadLocked; // bàn phím đang bị khoá 5 phút vì sai PIN 5 lần

  @override
  List<Object?> get props => [unlocked, uptime, unlockCount, pairedPhones, pairingMode, isAdmin, keypadLocked];
}

/// Use case: đọc trạng thái khoá (không cần sinh trắc học – chỉ đọc, không mở cửa).
class ReadLockStatus {
  ReadLockStatus(this._keys, this._sender);

  final LockKeyStore _keys;
  final SecureCommandSender _sender;

  Future<LockStatus> call(String lockId) async {
    final cred = await _keys.read(lockId);
    if (cred == null) throw StateError('Điện thoại chưa ghép đôi với khoá này');
    return LockStatus.fromPayload(await _sender.send(cred, LockCmd.status));
  }
}

/// Use case: khoá lại ngay (không cần sinh trắc học – khoá cửa luôn an toàn).
class LockNow {
  LockNow(this._keys, this._sender);

  final LockKeyStore _keys;
  final SecureCommandSender _sender;

  Future<void> call(String lockId) async {
    final cred = await _keys.read(lockId);
    if (cred == null) throw StateError('Điện thoại chưa ghép đôi với khoá này');
    await _sender.send(cred, LockCmd.lock);
  }
}
