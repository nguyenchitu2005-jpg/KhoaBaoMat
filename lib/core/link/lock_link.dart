import 'dart:typed_data';

/// Đường truyền tới khoá. Mọi đường (BLE, Wi-Fi trong nhà, máy chủ trung gian) chuyển CÙNG một
/// loại gói: xin nonce, lệnh đã mã hoá AES-GCM, phản hồi đã mã hoá. Lớp mã hoá
/// (SecureCommandSender) không cần biết gói đang đi đường nào.
abstract interface class LockTransport {
  /// Mọi gói khoá gửi về.
  Stream<Uint8List> get frames;

  /// Gửi 1 gói rồi chờ gói trả về đầu tiên có byte đầu thuộc [replyKinds].
  Future<Uint8List> request(List<int> frame, {required Set<int> replyKinds, Duration timeout});
}

enum LockRoute { ble, lan, remote }

/// Đường đang dùng cho khoá đang mở trên màn hình. DeviceCubit đặt [route] khi kết nối:
/// Wi-Fi trong nhà nếu thấy khoá trong mạng, máy chủ trung gian nếu khoá online, không thì BLE.
class LockLink implements LockTransport {
  LockLink(this._ble, this._lan, this._remote);

  final LockTransport _ble;
  final LockTransport _lan;
  final LockTransport _remote;
  LockRoute route = LockRoute.ble;

  LockTransport get _active => switch (route) {
        LockRoute.ble => _ble,
        LockRoute.lan => _lan,
        LockRoute.remote => _remote,
      };

  @override
  Stream<Uint8List> get frames => _active.frames;

  @override
  Future<Uint8List> request(List<int> frame, {required Set<int> replyKinds, Duration timeout = const Duration(seconds: 5)}) =>
      _active.request(frame, replyKinds: replyKinds, timeout: timeout);
}
