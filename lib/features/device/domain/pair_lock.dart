import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../../core/ble/lock_protocol.dart';
import '../../../core/crypto/lock_crypto.dart';
import '../../../core/storage/lock_key_store.dart';
import '../data/ble_lock_data_source.dart';

class PairingException implements Exception {
  const PairingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thông tin của 1 lần ghép đôi đang chờ người dùng gõ mã trên bàn phím của khoá.
class PairingSession {
  const PairingSession({required this.keyId, required this.confirmCode, required this.phoneKey});
  final int keyId;
  final String confirmCode; // 6 số – hiện trên app, người dùng gõ trên bàn phím của khoá
  final SecretKey phoneKey;
}

/// Use case ghép đôi điện thoại với khoá (khoá phải đang ở chế độ ghép đôi: giữ nút trong nhà 5 giây).
///
/// 1. [begin]: gửi khoá công khai X25519 → nhận khoá công khai của khoá → tính khoá AES + mã 6 số.
/// 2. [waitConfirmed]: chờ khoá báo người dùng đã gõ đúng mã → lưu khoá AES vào secure storage.
class PairLock {
  PairLock(this._ble, this._crypto, this._keys);

  final BleLockDataSource _ble;
  final LockCrypto _crypto;
  final LockKeyStore _keys;

  Future<PairingSession> begin() async {
    final myKeyPair = await _crypto.newPairingKeyPair();
    final myPublic = (await myKeyPair.extractPublicKey()).bytes;
    final reply = await _ble.request(
      [FrameKind.pairRequest, ...myPublic],
      replyKinds: {FrameKind.pairResponse, FrameKind.pairError},
    );
    if (reply[0] == FrameKind.pairError) {
      throw PairingException(PairStatus.describe(reply.length > 1 ? reply[1] : -1));
    }
    if (reply.length != 34) throw const PairingException('Gói trả lời ghép đôi không hợp lệ');

    final keyId = reply[33];
    final secrets = await _crypto.completePairing(
      myKeyPair: myKeyPair,
      lockPublicKey: reply.sublist(1, 33),
      keyId: keyId,
    );
    return PairingSession(keyId: keyId, confirmCode: secrets.confirmCode, phoneKey: secrets.phoneKey);
  }

  Future<void> waitConfirmed(String lockId, PairingSession session) async {
    final Uint8List result;
    try {
      result = await _ble.frames
          .firstWhere((f) => f.isNotEmpty && f[0] == FrameKind.pairResult)
          .timeout(const Duration(seconds: 75)); // khoá cho 60 giây để gõ mã
    } on TimeoutException {
      throw PairingException(PairStatus.describe(PairStatus.timeout));
    }
    final status = result.length > 1 ? result[1] : -1;
    if (status != PairStatus.ok) throw PairingException(PairStatus.describe(status));
    await _keys.save(lockId, session.keyId, session.phoneKey);
  }
}
