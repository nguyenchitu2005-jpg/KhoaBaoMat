import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// UUID dịch vụ BLE của khoá (tự định nghĩa, 128-bit) – phải trùng với firmware ESP32.
abstract final class LockUuids {
  static final service = Guid('8a1c0001-5b7e-4e2b-9b6a-3c4d5e6f7a80');
  static final command = Guid('8a1c0002-5b7e-4e2b-9b6a-3c4d5e6f7a80'); // App → Khoá (write)
  static final event = Guid('8a1c0003-5b7e-4e2b-9b6a-3c4d5e6f7a80'); // Khoá → App (notify)
  static final log = Guid('8a1c0004-5b7e-4e2b-9b6a-3c4d5e6f7a80'); // Khoá → App (notify, nhật ký)
}

/// Byte đầu tiên của mỗi gói BLE cho biết loại gói.
abstract final class FrameKind {
  static const challengeRequest = 0x01; // App → Khoá, bản rõ: [0x01][keyId]
  static const sealedCommand = 0x02; // App → Khoá, đã mã hoá: [0x02][keyId][IV 12][bản mã][tag 16]
  static const pairRequest = 0x03; // App → Khoá: [0x03][khoá công khai X25519 32B]
  static const challenge = 0x81; // Khoá → App, bản rõ: [0x81][nonce 8]
  static const sealedReply = 0x82; // Khoá → App, đã mã hoá, cùng định dạng với 0x02
  static const pairResponse = 0x83; // Khoá → App: [0x83][khoá công khai của khoá 32B][keyId]
  static const pairResult = 0x84; // Khoá → App: [0x84][kết quả][keyId] – sau khi gõ mã trên bàn phím
  static const pairError = 0x85; // Khoá → App: [0x85][mã lỗi]
  static const progress = 0x86; // Khoá → App: [0x86][cmd][bước] – tiến trình đăng ký vân tay, không mã hoá
}

/// Kết quả / lỗi ghép đôi (byte thứ 2 của gói 0x84 / 0x85).
abstract final class PairStatus {
  static const ok = 0x00;
  static const badCode = 0x01;
  static const timeout = 0x02;
  static const notInPairingMode = 0x10;
  static const full = 0x11;
  static const busy = 0x12;

  static String describe(int code) => switch (code) {
        ok => 'Ghép đôi thành công',
        badCode => 'Gõ sai mã quá 3 lần – hãy thử lại từ đầu',
        timeout => 'Hết 60 giây mà chưa gõ mã trên bàn phím',
        notInPairingMode => 'Khoá chưa ở chế độ ghép đôi – giữ nút trong nhà 5 giây đến khi đèn xanh nhấp nháy',
        full => 'Khoá đã đủ số điện thoại tối đa',
        busy => 'Khoá đang ghép đôi với điện thoại khác',
        _ => 'Ghép đôi thất bại (0x${code.toRadixString(16)})',
      };
}

/// Mã lệnh nằm trong phần đã mã hoá.
abstract final class LockCmd {
  static const unlock = 0x10;
  static const lock = 0x11;
  static const status = 0x12;
  static const syncTime = 0x13;
  static const getLogs = 0x20;
  static const enrollRfid = 0x30;
  static const deleteRfid = 0x31;
  static const enrollFinger = 0x32;
  static const deleteFinger = 0x33;
  static const setPin = 0x34;
  static const setGuestPin = 0x35;
  static const listAccess = 0x36;
  static const listPhones = 0x37;
  static const setWifi = 0x38; // [độ dài tên][tên][độ dài mật khẩu][mật khẩu]; độ dài tên 0 = quên Wi-Fi
  static const wifiStatus = 0x39; // → [trạng thái][sóng dBm][IP 4B][giờ NTP][độ dài tên][tên]
  static const setMqtt = 0x3A; // [độ dài host][host][cổng 2B][độ dài user][user][độ dài mk][mk]; host rỗng = tắt
  static const mqttStatus = 0x3B; // → [trạng thái][độ dài host][host]
  static const revokePhone = 0x41;
}

/// Mã kết quả khoá trả về.
abstract final class LockResult {
  static const ok = 0x00;
  static const badNonce = 0x01; // nonce sai / hết hạn / đã dùng
  static const badCounter = 0x02; // bộ đếm không tăng → nghi phát lại
  static const denied = 0x03; // khoá của điện thoại bị thu hồi / không đủ quyền
  static const busy = 0x04; // khoá đang bận (đang đăng ký vân tay…)
  static const unknownCmd = 0x05;
  static const timeout = 0x06; // hết giờ chờ quẹt thẻ / đặt tay
  static const enrollFail = 0x07; // 2 lần đặt tay không khớp / lỗi cảm biến
  static const full = 0x08;
  static const badArg = 0x09;
  static const exists = 0x0A; // thẻ / vân tay đã được đăng ký
  static const noSensor = 0x0B; // khoá không nối được RC522 / AS608

  static String describe(int code) => switch (code) {
        ok => 'Thành công',
        badNonce => 'Phiên đã hết hạn, thử lại',
        badCounter => 'Gói tin bị phát lại – đã từ chối',
        denied => 'Điện thoại này không có quyền thực hiện lệnh này',
        busy => 'Khoá đang bận',
        unknownCmd => 'Khoá không hiểu lệnh – hãy cập nhật firmware',
        timeout => 'Hết giờ chờ',
        enrollFail => 'Hai lần đặt tay không khớp, hãy thử lại',
        full => 'Khoá đã hết chỗ lưu',
        badArg => 'Tham số không hợp lệ',
        exists => 'Thẻ / vân tay này đã được đăng ký',
        noSensor => 'Khoá không kết nối được đầu đọc – kiểm tra dây',
        _ => 'Lỗi không xác định (0x${code.toRadixString(16)})',
      };
}
