// Test với ESP32 thật qua Bluetooth (chạy trên Windows có BLE hoặc điện thoại Android):
//   flutter test integration_test/ble_lock_test.dart -d windows
// Yêu cầu: ESP32 đang chạy firmware/smart_lock và ở gần máy.
// Nếu máy chưa ghép đôi: GIỮ NÚT TRONG NHÀ (nút BOOT) 5 giây rồi gõ mã 6 số in ra log vào bàn phím của khoá.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:khoabaomat/core/ble/lock_protocol.dart';
import 'package:khoabaomat/core/ble/secure_command_sender.dart';
import 'package:khoabaomat/core/di/injection.dart';
import 'package:khoabaomat/core/storage/lock_key_store.dart';
import 'package:khoabaomat/features/device/data/ble_lock_data_source.dart';
import 'package:khoabaomat/features/device/domain/lock_status.dart';
import 'package:khoabaomat/features/device/domain/pair_lock.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  configureDependencies();

  testWidgets('quét → kết nối → (ghép đôi) → STATUS → MỞ → STATUS → KHOÁ', (tester) async {
    final ble = sl<BleLockDataSource>();
    final keys = sl<LockKeyStore>();
    final sender = sl<SecureCommandSender>();
    final readStatus = sl<ReadLockStatus>();
    await keys.purgeDemoKeys();

    // 1. Quét theo service UUID
    final results = await ble.scan(timeout: const Duration(seconds: 15));
    final found = await results.firstWhere((l) => l.isNotEmpty).timeout(const Duration(seconds: 20));
    await ble.stopScan();
    final device = found.first.device;
    debugPrint('Tìm thấy: ${device.platformName} ${device.remoteId} RSSI ${found.first.rssi}');

    // 2. Kết nối
    await ble.connect(device);
    expect(device.isConnected, isTrue);
    final lockId = device.remoteId.str;

    // 3. Ghép đôi nếu máy này chưa có khoá AES (thử lại mỗi 3 giây cho tới khi khoá vào chế độ ghép đôi)
    if (await keys.read(lockId) == null) {
      final pair = sl<PairLock>();
      PairingSession? session;
      debugPrint('>>> GIỮ NÚT BOOT 5 giây để khoá vào chế độ ghép đôi <<<');
      for (var i = 0; i < 30 && session == null; i++) {
        try {
          session = await pair.begin();
        } on PairingException {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      expect(session, isNotNull, reason: 'Khoá không vào chế độ ghép đôi');
      debugPrint('>>> GÕ MÃ ${session!.confirmCode} TRÊN BÀN PHÍM CỦA KHOÁ <<<');
      await pair.waitConfirmed(lockId, session);
      debugPrint('Ghép đôi thành công, keyId ${session.keyId}');
    }
    final cred = (await keys.read(lockId))!;

    // 4. STATUS
    final before = await readStatus(lockId);
    debugPrint('Trước: mở=${before.unlocked}, ${before.unlockCount} lần, ${before.pairedPhones} điện thoại');

    // 5. MỞ (gửi thẳng lệnh, bỏ qua sinh trắc học vì test tự động)
    await sender.send(cred, LockCmd.unlock);
    final opened = await readStatus(lockId);
    expect(opened.unlocked, isTrue);
    expect(opened.unlockCount, before.unlockCount + 1);

    // 6. KHOÁ ngay
    await sender.send(cred, LockCmd.lock);
    final closed = await readStatus(lockId);
    expect(closed.unlocked, isFalse);
    debugPrint('Sau: mở=${closed.unlocked}, ${closed.unlockCount} lần');

    await ble.disconnect();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
