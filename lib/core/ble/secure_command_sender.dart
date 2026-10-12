import 'dart:typed_data';

import '../../features/device/data/ble_lock_data_source.dart';
import '../crypto/lock_crypto.dart';
import '../storage/lock_key_store.dart';
import 'lock_protocol.dart';

/// Khoá trả về mã kết quả khác OK.
class LockCommandException implements Exception {
  const LockCommandException(this.result);
  final int result;
  String get message => LockResult.describe(result);
  @override
  String toString() => message;
}

/// Gửi 1 lệnh an toàn tới khoá: xin nonce → mã hoá AES-GCM → gửi → giải mã và kiểm tra phản hồi.
/// Dùng chung cho mọi lệnh (UNLOCK, LOCK, STATUS…). Trả về phần payload của phản hồi.
class SecureCommandSender {
  SecureCommandSender(this._ble, this._keys, this._crypto);

  final BleLockDataSource _ble;
  final LockKeyStore _keys;
  final LockCrypto _crypto;

  /// [timeout]: thời gian chờ phản hồi của lệnh (lệnh đăng ký thẻ / vân tay phải chờ người dùng thao tác).
  Future<Uint8List> send(
    LockCredential cred,
    int cmd, {
    List<int> payload = const [],
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // 1. Xin nonce dùng 1 lần (chống phát lại gói cũ)
    final challenge = await _ble.request(
      [FrameKind.challengeRequest, cred.keyId],
      replyKinds: {FrameKind.challenge},
    );
    if (challenge.length != 9) throw const FormatException('Gói challenge không hợp lệ');

    // 2. Mã hoá lệnh kèm nonce + bộ đếm tăng dần
    final counter = await _keys.nextCounter(cred.lockId);
    final sealed = await _crypto.sealCommand(
      phoneKey: cred.key,
      keyId: cred.keyId,
      cmd: cmd,
      counter: counter,
      lockNonce: challenge.sublist(1, 9),
      payload: payload,
    );
    final reply = await _ble.request(
      [FrameKind.sealedCommand, ...sealed],
      replyKinds: {FrameKind.sealedReply},
      timeout: timeout,
    );

    // 3. Phản hồi: [cmd][result][counter 4B][payload…] – phải khớp lệnh vừa gửi
    final plain = await _crypto.open(phoneKey: cred.key, sealed: reply.sublist(1));
    if (plain.length < 6 || plain[0] != cmd || LockCrypto.readU32(plain, 2) != counter) {
      throw const FormatException('Phản hồi không khớp lệnh vừa gửi');
    }
    if (plain[1] != LockResult.ok) throw LockCommandException(plain[1]);
    return Uint8List.sublistView(plain, 6);
  }
}
