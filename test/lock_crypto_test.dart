import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khoabaomat/core/ble/lock_protocol.dart';
import 'package:khoabaomat/core/crypto/lock_crypto.dart';

void main() {
  final crypto = LockCrypto();

  test('ghép đôi: điện thoại và khoá tính ra cùng khoá AES và cùng mã xác nhận', () async {
    final phone = await crypto.newPairingKeyPair();
    final lock = await crypto.newPairingKeyPair(); // giả lập phía ESP32
    final phonePub = (await phone.extractPublicKey()).bytes;
    final lockPub = (await lock.extractPublicKey()).bytes;

    final a = await crypto.completePairing(myKeyPair: phone, lockPublicKey: lockPub, keyId: 3);
    final b = await crypto.completePairing(myKeyPair: lock, lockPublicKey: phonePub, keyId: 3);

    expect(await a.phoneKey.extractBytes(), await b.phoneKey.extractBytes());
    expect(a.confirmCode, b.confirmCode);
    expect(a.confirmCode, matches(RegExp(r'^\d{6}$')));
  });

  // Vector cố định tạo bằng Python (cryptography) – script Python này đã ghép đôi thành công với ESP32 (mbedtls),
  // nên Dart khớp vector = Dart khớp firmware.
  test('ghép đôi khớp vector chuẩn (Python / ESP32 mbedtls)', () async {
    List<int> hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
    final phone = await X25519().newKeyPairFromSeed(List<int>.generate(32, (i) => i + 1));
    expect((await phone.extractPublicKey()).bytes,
        hex('07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c'));

    final s = await crypto.completePairing(
      myKeyPair: phone,
      lockPublicKey: hex('5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c36'),
      keyId: 3,
    );
    expect(await s.phoneKey.extractBytes(),
        hex('a273fc4a9ddadd593d96513777f2f7d691848298d9d57f4cb16329e5c8101815'));
    expect(s.confirmCode, '758760');
  });

  test('lệnh UNLOCK: khoá giải mã được đúng các trường', () async {
    final key = SecretKey(List<int>.generate(32, (i) => i));
    final nonce = [1, 2, 3, 4, 5, 6, 7, 8];
    final sealed = await crypto.sealCommand(
      phoneKey: key, keyId: 3, cmd: LockCmd.unlock, counter: 42, lockNonce: nonce,
      now: DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000),
    );

    final plain = await crypto.open(phoneKey: key, sealed: sealed); // cùng định dạng 2 chiều
    expect(sealed[0], 3);
    expect(plain[0], LockCmd.unlock);
    expect(LockCrypto.readU32(plain, 1), 42);
    expect(plain.sublist(5, 13), nonce);
    expect(LockCrypto.readU32(plain, 13), 1760000000);
  });

  test('gói bị sửa 1 bit hoặc đổi keyId thì bị từ chối', () async {
    final key = SecretKey(List<int>.generate(32, (i) => i));
    final sealed = await crypto.sealCommand(
      phoneKey: key, keyId: 3, cmd: LockCmd.unlock, counter: 1, lockNonce: List.filled(8, 0),
    );
    final flipped = [...sealed]..[20] ^= 0x01;
    final otherId = [...sealed]..[0] = 4;
    await expectLater(crypto.open(phoneKey: key, sealed: flipped), throwsA(isA<SecretBoxAuthenticationError>()));
    await expectLater(crypto.open(phoneKey: key, sealed: otherId), throwsA(isA<SecretBoxAuthenticationError>()));
  });
}
