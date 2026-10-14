import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thông tin bí mật của 1 khoá đã ghép đôi với điện thoại này.
class LockCredential {
  const LockCredential({required this.lockId, required this.keyId, required this.key});

  final String lockId; // địa chỉ BLE (remoteId) của khoá
  final int keyId; // số thứ tự điện thoại trong bộ nhớ của khoá (1..N)
  final SecretKey key; // khoá AES-256 riêng của điện thoại
}

/// Lưu khoá AES và bộ đếm chống phát lại trong flutter_secure_storage
/// (Android Keystore / iOS Keychain). Không bao giờ ghi ra SharedPreferences hay file thường.
class LockKeyStore {
  LockKeyStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _name(String lockId) => 'lock.$lockId';

  Future<void> save(String lockId, int keyId, SecretKey key) async {
    final bytes = await key.extractBytes();
    await _storage.write(
      key: _name(lockId),
      value: jsonEncode({'keyId': keyId, 'key': base64Encode(bytes), 'counter': 0}),
    );
  }

  Future<LockCredential?> read(String lockId) async {
    final raw = await _storage.read(key: _name(lockId));
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return LockCredential(
      lockId: lockId,
      keyId: m['keyId'] as int,
      key: SecretKey(base64Decode(m['key'] as String)),
    );
  }

  /// Tăng và trả về bộ đếm lệnh. Khoá chỉ nhận lệnh có bộ đếm lớn hơn lần trước.
  Future<int> nextCounter(String lockId) async {
    final raw = await _storage.read(key: _name(lockId));
    if (raw == null) throw StateError('Khoá $lockId chưa ghép đôi');
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final next = (m['counter'] as int) + 1;
    m['counter'] = next;
    await _storage.write(key: _name(lockId), value: jsonEncode(m));
    return next;
  }

  Future<void> remove(String lockId) => _storage.delete(key: _name(lockId));

  /// Địa chỉ các khoá đã ghép đôi (để mở được khoá qua Wi-Fi khi không quét thấy qua Bluetooth).
  Future<List<String>> pairedLockIds() async => [
        for (final k in (await _storage.readAll()).keys)
          if (k.startsWith('lock.')) k.substring('lock.'.length),
      ];

  /// Xoá khoá thử nghiệm toàn số 0 còn sót từ giai đoạn 1 (trước khi có ghép đôi).
  Future<void> purgeDemoKeys() async {
    final all = await _storage.readAll();
    for (final e in all.entries) {
      if (!e.key.startsWith('lock.')) continue;
      final m = jsonDecode(e.value) as Map<String, dynamic>;
      if (base64Decode(m['key'] as String).every((b) => b == 0)) await _storage.delete(key: e.key);
    }
  }
}
