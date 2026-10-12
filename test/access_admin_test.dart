import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khoabaomat/core/ble/lock_protocol.dart';
import 'package:khoabaomat/core/ble/secure_command_sender.dart';
import 'package:khoabaomat/core/storage/lock_key_store.dart';
import 'package:khoabaomat/features/access/domain/access_admin.dart';
import 'package:khoabaomat/features/device/data/ble_lock_data_source.dart';
import 'package:khoabaomat/features/device/domain/lock_status.dart';
import 'package:mocktail/mocktail.dart';

class MockKeys extends Mock implements LockKeyStore {}

class MockSender extends Mock implements SecureCommandSender {}

class MockBle extends Mock implements BleLockDataSource {}

/// 1 bản ghi nhật ký 16 byte như firmware ghi (thời gian little-endian).
List<int> record(int time, int flags, int method, int who, int result, [List<int> extra = const []]) => [
      time & 0xFF, (time >> 8) & 0xFF, (time >> 16) & 0xFF, (time >> 24) & 0xFF,
      flags, method, who, result,
      ...extra, ...List.filled(8 - extra.length, 0),
    ];

List<int> u32(int v) => [v >> 24, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

void main() {
  const lockId = 'AA:BB:CC:DD:EE:FF';
  final cred = LockCredential(lockId: lockId, keyId: 1, key: SecretKey(List.filled(32, 7)));
  late MockSender sender;
  late AccessAdmin admin;

  setUpAll(() {
    registerFallbackValue(cred);
    registerFallbackValue(Duration.zero);
  });
  setUp(() {
    final keys = MockKeys();
    when(() => keys.read(lockId)).thenAnswer((_) async => cred);
    sender = MockSender();
    admin = AccessAdmin(keys, sender, MockBle());
  });

  test('AccessList đọc đúng payload LIST_ACCESS', () {
    final list = AccessList.fromPayload([
      1, // có PIN
      0x80, 0, 0, 0x05, // vân tay 1, 3, 32
      2, // 2 thẻ
      0, 4, 0x04, 0xA1, 0xB2, 0xC3,
      3, 7, 1, 2, 3, 4, 5, 6, 7,
    ]);
    expect(list.hasPin, isTrue);
    expect(list.fingerIds, [1, 3, 32]);
    expect(list.cards, const [CardEntry(0, '04:A1:B2:C3'), CardEntry(3, '01:02:03:04:05:06:07')]);
    expect(() => AccessList.fromPayload([0, 0, 0, 0, 0, 1, 0, 4, 1]), throwsFormatException); // thẻ bị cắt
  });

  test('LogEntry đọc đúng bản ghi 16 byte', () {
    final opened = LogEntry.fromBytes(record(1791800000, 1, 2, 4, 0));
    expect(opened.time, DateTime.fromMillisecondsSinceEpoch(1791800000 * 1000));
    expect(opened.opened, isTrue);
    expect(opened.title, 'Mở bằng thẻ 5');

    final stranger = LogEntry.fromBytes(record(42, 0, 2, 0, 1, [0xDE, 0xAD, 0xBE, 0xEF]));
    expect(stranger.time, isNull); // khoá chưa đồng bộ giờ
    expect(stranger.title, 'Thẻ lạ DE:AD:BE:EF');
  });

  test('LockStatus nhận vai trò admin từ firmware giai đoạn 3', () {
    expect(LockStatus.fromPayload([0, 0, 0, 0, 5, 0, 0, 0, 0, 2, 0, 1, 1]).isAdmin, isTrue);
    expect(LockStatus.fromPayload([0, 0, 0, 0, 5, 0, 0, 0, 0, 2, 0, 2, 0]).isAdmin, isFalse);
    expect(LockStatus.fromPayload([0, 0, 0, 0, 5, 0, 0, 0, 0, 2, 0]).isAdmin, isFalse); // firmware cũ
  });

  test('readLogs lấy các bản ghi mới nhất qua nhiều lần hỏi, mới nhất đứng đầu', () async {
    // Khoá có 15 bản ghi (số 0..14), mỗi lần trả tối đa 12 như firmware.
    final asked = <int>[];
    when(() => sender.send(any(), LockCmd.getLogs, payload: any(named: 'payload'), timeout: any(named: 'timeout')))
        .thenAnswer((inv) async {
      final p = inv.namedArguments[#payload] as List<int>;
      final from = min((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3], 15);
      asked.add(from);
      final n = min(15 - from, 12);
      return Uint8List.fromList([
        ...u32(15), ...u32(from), n,
        for (var i = 0; i < n; i++) ...record(1791800000 + from + i, 1, 5, 0, 0),
      ]);
    });

    final logs = await admin.readLogs(lockId, count: 14);

    expect(asked, [15, 1, 13]); // lần đầu hỏi quá cuối để biết tổng
    expect(logs, hasLength(14));
    expect(logs.first.time, DateTime.fromMillisecondsSinceEpoch((1791800000 + 14) * 1000));
    expect(logs.last.time, DateTime.fromMillisecondsSinceEpoch((1791800000 + 1) * 1000));
  });

  test('setPin gửi [độ dài][chữ số ASCII] và từ chối mã không hợp lệ', () async {
    when(() => sender.send(any(), any(), payload: any(named: 'payload'), timeout: any(named: 'timeout')))
        .thenAnswer((_) async => Uint8List(0));

    await admin.setPin(lockId, '1234');
    await admin.setPin(lockId, '');

    verify(() => sender.send(cred, LockCmd.setPin, payload: [4, 0x31, 0x32, 0x33, 0x34], timeout: any(named: 'timeout')))
        .called(1);
    verify(() => sender.send(cred, LockCmd.setPin, payload: [0], timeout: any(named: 'timeout'))).called(1);
    expect(() => admin.setPin(lockId, '12a4'), throwsArgumentError);
    expect(() => admin.setPin(lockId, '123'), throwsArgumentError);
  });
}
