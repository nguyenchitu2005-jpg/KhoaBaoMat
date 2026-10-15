import 'package:flutter_test/flutter_test.dart';
import 'package:khoabaomat/features/device/data/lan_lock_data_source.dart';
import 'package:khoabaomat/features/device/data/mqtt_lock_data_source.dart';

void main() {
  test('đóng gói LAN: [độ dài 2B big-endian][gói]', () {
    expect(encodeLanFrame([0x01, 0x07]), [0, 2, 0x01, 0x07]);
    expect(encodeLanFrame(List.filled(300, 9)).sublist(0, 2), [1, 44]); // 300 = 0x012C
  });

  test('tách gói LAN khi TCP gộp nhiều gói hoặc cắt 1 gói làm nhiều lần', () {
    final d = LanFrameDecoder();
    // 2 gói dính nhau, gói thứ 3 mới tới một nửa
    expect(d.add([0, 1, 0x81, 0, 2, 0x82, 0x55, 0, 3, 0xAA]), [
      [0x81],
      [0x82, 0x55],
    ]);
    expect(d.add([0xBB]), isEmpty); // vẫn thiếu 1 byte
    expect(d.add([0xCC, 0]), [
      [0xAA, 0xBB, 0xCC],
    ]); // byte 0 cuối là nửa đầu độ dài gói sau
    expect(d.add([1, 0x84]), [
      [0x84],
    ]);
    expect(() => LanFrameDecoder().add([0, 0]), throwsFormatException); // gói rỗng = luồng hỏng
  });

  test('địa chỉ BLE -> 6 byte; iOS (UUID) không dùng được Wi-Fi', () {
    expect(macBytes('20:50:0D:4D:AA:B2'), [0x20, 0x50, 0x0D, 0x4D, 0xAA, 0xB2]);
    expect(macBytes('6F1B2C3D-1111-2222-3333-444455556666'), isNull);
    expect(macBytes('20:50:0D:4D:AA'), isNull);
    expect(macBytes('20:50:0D:4D:AA:ZZ'), isNull);
  });

  test('hỏi thẳng từng địa chỉ trong mạng /24, trừ chính điện thoại', () {
    final t = sweepTargets('192.168.1.5');
    expect(t, hasLength(253));
    expect(t.first, '192.168.1.1');
    expect(t.last, '192.168.1.254');
    expect(t, isNot(contains('192.168.1.5')));
    expect(t, contains('192.168.1.36')); // IP khoá lúc thử thực tế
    expect(sweepTargets('khong-phai-ip'), isEmpty);
  });

  test('gói tìm khoá: chỉ nhận lời của đúng khoá', () {
    const mac = [0x20, 0x50, 0x0D, 0x4D, 0xAA, 0xB2];
    expect(discoveryQuery(mac), [...'KBM?'.codeUnits, ...mac]);
    expect(isDiscoveryReply([...'KBM!'.codeUnits, ...mac], mac), isTrue);
    expect(isDiscoveryReply([...'KBM!'.codeUnits, 0x20, 0x50, 0x0D, 0x4D, 0xAA, 0xB3], mac), isFalse); // khoá khác
    expect(isDiscoveryReply([...'KBM?'.codeUnits, ...mac], mac), isFalse); // gói hỏi của máy khác
    expect(isDiscoveryReply('KBM!'.codeUnits, mac), isFalse);
  });

  test('chủ đề MQTT khớp firmware: khoabaomat/<địa chỉ BLE 12 hex thường>/c|e|s', () {
    final t = lockTopics('20:50:0D:4D:AA:B2')!;
    expect(t.cmd, 'khoabaomat/20500d4daab2/c');
    expect(t.evt, 'khoabaomat/20500d4daab2/e');
    expect(t.status, 'khoabaomat/20500d4daab2/s');
    expect(lockTopics('6F1B2C3D-1111-2222-3333-444455556666'), isNull); // iOS: không có địa chỉ MAC
  });
}
