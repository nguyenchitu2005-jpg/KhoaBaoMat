import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Kết quả ghép đôi: khoá AES riêng của điện thoại + mã 6 số để người dùng
/// gõ trên bàn phím của khoá (xác nhận không có ai chen giữa – chống MITM).
typedef PairingSecrets = ({SecretKey phoneKey, String confirmCode});

/// Mã hoá lệnh gửi khoá bằng AES-256-GCM.
///
/// Gói đã mã hoá: `[keyId 1B][IV 12B][bản mã][tag 16B]`, keyId được đưa vào AAD.
/// Bản rõ của lệnh: `[cmd 1B][counter 4B][lockNonce 8B][unixTime 4B][payload…]`.
class LockCrypto {
  LockCrypto({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  static final _aes = AesGcm.with256bits();
  static final _x25519 = X25519();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static const ivLength = 12;
  static const tagLength = 16;

  // ---------------- Ghép đôi (chỉ chạy 1 lần cho mỗi điện thoại) ----------------

  Future<SimpleKeyPair> newPairingKeyPair() => _x25519.newKeyPair();

  /// ECDH X25519 → HKDF-SHA256 → khoá AES 32 byte cho cặp (điện thoại, khoá) và mã xác nhận.
  Future<PairingSecrets> completePairing({
    required SimpleKeyPair myKeyPair,
    required List<int> lockPublicKey,
    required int keyId,
  }) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(lockPublicKey, type: KeyPairType.x25519),
    );
    final salt = utf8.encode('khoabaomat-v1');
    final phoneKey = await _hkdf.deriveKey(secretKey: shared, nonce: salt, info: [keyId]);
    final codeKey = await _hkdf.deriveKey(secretKey: shared, nonce: salt, info: utf8.encode('confirm'));
    final b = await codeKey.extractBytes();
    final n = ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) & 0x7fffffff;
    return (phoneKey: phoneKey, confirmCode: (n % 1000000).toString().padLeft(6, '0'));
  }

  // ---------------- Lệnh hằng ngày ----------------

  Future<Uint8List> sealCommand({
    required SecretKey phoneKey,
    required int keyId,
    required int cmd,
    required int counter,
    required List<int> lockNonce,
    List<int> payload = const [],
    DateTime? now,
  }) async {
    final unixTime = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final plain = (BytesBuilder()
          ..addByte(cmd)
          ..add(_u32(counter))
          ..add(lockNonce)
          ..add(_u32(unixTime))
          ..add(payload))
        .toBytes();
    final iv = List<int>.generate(ivLength, (_) => _random.nextInt(256));
    final box = await _aes.encrypt(plain, secretKey: phoneKey, nonce: iv, aad: [keyId]);
    return Uint8List.fromList([keyId, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Giải mã gói trả về từ khoá. Gói bị sửa dù 1 bit → ném [SecretBoxAuthenticationError].
  Future<Uint8List> open({required SecretKey phoneKey, required List<int> sealed}) async {
    if (sealed.length < 1 + ivLength + tagLength) {
      throw const FormatException('Gói mã hoá quá ngắn');
    }
    final box = SecretBox(
      sealed.sublist(1 + ivLength, sealed.length - tagLength),
      nonce: sealed.sublist(1, 1 + ivLength),
      mac: Mac(sealed.sublist(sealed.length - tagLength)),
    );
    final plain = await _aes.decrypt(box, secretKey: phoneKey, aad: [sealed[0]]);
    return Uint8List.fromList(plain);
  }

  static List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

  static int readU32(List<int> b, int offset) =>
      (b[offset] << 24) | (b[offset + 1] << 16) | (b[offset + 2] << 8) | b[offset + 3];
}
