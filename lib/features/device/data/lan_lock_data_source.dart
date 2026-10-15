import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/link/lock_link.dart';
import 'ble_lock_data_source.dart';

/// Cổng của khoá trong mạng nhà: TCP nhận lệnh, UDP trả lời khi app tìm khoá (firmware: LAN_PORT).
const kLanPort = 4545;

/// Đóng gói cho TCP: `[độ dài 2B big-endian][gói]` (TCP không giữ ranh giới giữa các gói).
Uint8List encodeLanFrame(List<int> frame) =>
    Uint8List.fromList([frame.length >> 8, frame.length & 0xFF, ...frame]);

/// Tách luồng byte TCP thành từng gói `[độ dài 2B][gói]`.
class LanFrameDecoder {
  final List<int> _pending = [];

  /// Thêm byte vừa nhận, trả về các gói đã nhận đủ.
  List<Uint8List> add(List<int> bytes) {
    _pending.addAll(bytes);
    final out = <Uint8List>[];
    while (_pending.length >= 2) {
      final len = (_pending[0] << 8) | _pending[1];
      if (len == 0) throw const FormatException('Gói LAN rỗng');
      if (_pending.length < 2 + len) break;
      out.add(Uint8List.fromList(_pending.sublist(2, 2 + len)));
      _pending.removeRange(0, 2 + len);
    }
    return out;
  }
}

/// Địa chỉ BLE dạng `20:50:0D:4D:AA:B2` -> 6 byte. null nếu không phải địa chỉ MAC
/// (iOS đặt tên thiết bị BLE bằng UUID nên không tìm được khoá qua Wi-Fi).
List<int>? macBytes(String lockId) {
  final parts = lockId.split(':');
  if (parts.length != 6 || parts.any((p) => p.length != 2)) return null;
  final out = [for (final p in parts) int.tryParse(p, radix: 16) ?? -1];
  return out.every((b) => b >= 0) ? out : null;
}

/// Gói tìm khoá: app gửi `KBM?` + địa chỉ BLE, khoá đúng địa chỉ trả `KBM!` + cùng địa chỉ.
List<int> discoveryQuery(List<int> mac) => [...'KBM?'.codeUnits, ...mac];

bool isDiscoveryReply(List<int> data, List<int> mac) {
  if (data.length != 10) return false;
  for (var i = 0; i < 4; i++) {
    if (data[i] != 'KBM!'.codeUnitAt(i)) return false;
  }
  for (var i = 0; i < 6; i++) {
    if (data[4 + i] != mac[i]) return false;
  }
  return true;
}

/// Lớp dữ liệu Wi-Fi trong nhà: tìm khoá trong cùng mạng, gửi/nhận đúng các gói như BLE qua TCP.
/// Không biết gì về mã hoá – chỉ chuyển byte (giống BleLockDataSource).
class LanLockDataSource implements LockTransport {
  LanLockDataSource([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final _frames = StreamController<Uint8List>.broadcast();
  Socket? _socket;
  String? _lockId;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  bool get isConnected => _socket != null;

  /// Tìm khoá trong mạng Wi-Fi đang dùng rồi mở kết nối. false = không thấy khoá
  /// (điện thoại khác mạng, khoá chưa có Wi-Fi, router chặn các máy thấy nhau…).
  Future<bool> connect(String lockId) async {
    disconnect();
    final mac = macBytes(lockId);
    if (mac == null) return false;
    _lockId = lockId;
    // Thử IP lần trước (nhanh); đổi IP (router cấp lại) thì hỏi cả mạng
    final cached = await _storage.read(key: 'lan.$lockId');
    if (cached != null && await _open(cached)) return true;
    final found = await discover(mac);
    if (found == null || found == cached || !await _open(found)) return false;
    await _storage.write(key: 'lan.$lockId', value: found);
    return true;
  }

  void disconnect() {
    _socket?.destroy();
    _socket = null;
  }

  /// Ghi nhớ IP khoá tự báo qua BLE (lệnh WIFI_STATUS). Cách chính để biết IP: khoá chạy cả BLE nên
  /// Wi-Fi phải ở chế độ tiết kiệm điện và hay lỡ gói broadcast tìm khoá.
  Future<void> rememberIp(String lockId, String ip) => _storage.write(key: 'lan.$lockId', value: ip);

  @override
  Future<Uint8List> request(
    List<int> frame, {
    required Set<int> replyKinds,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // Khoá đóng kết nối im lặng quá 2 phút: tự kết nối lại trước khi gửi
    final id = _lockId;
    if (_socket == null && (id == null || !await connect(id))) {
      throw const BleException('Không kết nối được khoá qua Wi-Fi – bật Bluetooth hoặc vào cùng mạng với khoá');
    }
    // Đăng ký nghe TRƯỚC khi ghi để không lỡ gói trả về quá nhanh.
    final reply = frames.firstWhere((f) => f.isNotEmpty && replyKinds.contains(f[0])).timeout(timeout);
    try {
      final s = _socket!;
      s.add(encodeLanFrame(frame));
      await s.flush();
    } catch (_) {
      reply.ignore();
      disconnect();
      throw const BleException('Mất kết nối Wi-Fi với khoá');
    }
    return reply;
  }

  Future<bool> _open(String ip) async {
    try {
      // Khoá đang "ngủ" Wi-Fi (tiết kiệm điện khi chạy chung BLE) có lúc trả lời chậm hơn 1 giây
      final s = await Socket.connect(ip, kLanPort, timeout: const Duration(seconds: 4));
      s.setOption(SocketOption.tcpNoDelay, true);
      final decoder = LanFrameDecoder();
      void closed() {
        if (identical(_socket, s)) _socket = null;
      }

      s.listen(
        (data) {
          try {
            decoder.add(data).forEach(_frames.add);
          } on FormatException {
            s.destroy();
            closed();
          }
        },
        onDone: closed,
        onError: (Object _) => closed(),
        cancelOnError: true,
      );
      _socket = s;
      return true;
    } on SocketException {
      return false;
    }
  }

  /// Hỏi "khoá có địa chỉ BLE này ở đâu?" qua UDP. Trả về IP hoặc null.
  /// Gửi broadcast VÀ hỏi thẳng từng địa chỉ trong mạng nhà: khoá chạy cả BLE nên Wi-Fi phải tiết kiệm
  /// điện và thường lỡ gói broadcast, còn gói gửi thẳng tới IP của khoá thì vẫn nhận (đã thử thực tế).
  static Future<String?> discover(List<int> mac, {Duration wait = const Duration(milliseconds: 2400)}) async {
    final targets = [
      InternetAddress('255.255.255.255'),
      for (final ip in await _localIPv4s()) ...sweepTargets(ip).map(InternetAddress.new),
    ];
    final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    udp.broadcastEnabled = true;
    final found = Completer<String>();
    final sub = udp.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = udp.receive();
      if (d != null && !found.isCompleted && isDiscoveryReply(d.data, mac)) found.complete(d.address.address);
    });
    try {
      final query = discoveryQuery(mac);
      // Gửi vài lượt: gói UDP có thể bị rơi, khoá đang "ngủ" Wi-Fi có thể lỡ lượt đầu
      for (var i = 0; i < 3 && !found.isCompleted; i++) {
        for (final t in targets) {
          udp.send(query, t, kLanPort);
        }
        await Future.any<Object?>([found.future, Future<void>.delayed(wait ~/ 3)]);
      }
      return found.isCompleted ? await found.future : null;
    } finally {
      await sub.cancel();
      udp.close();
    }
  }

  /// Địa chỉ IPv4 mạng nội bộ của điện thoại (Wi-Fi), bỏ qua 4G (thường là IP công cộng / 100.x).
  static Future<List<String>> _localIPv4s() async {
    final out = <String>[];
    for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in nic.addresses) {
        final p = a.address.split('.').map(int.parse).toList();
        final private = p[0] == 10 || (p[0] == 172 && p[1] >= 16 && p[1] <= 31) || (p[0] == 192 && p[1] == 168);
        if (private && !a.isLoopback) out.add(a.address);
      }
    }
    return out;
  }
}

/// Các địa chỉ cần hỏi trong mạng /24 của [ownIp] (mạng nhà gần như luôn là /24), trừ chính máy này.
List<String> sweepTargets(String ownIp) {
  final p = ownIp.split('.');
  if (p.length != 4) return const [];
  final prefix = '${p[0]}.${p[1]}.${p[2]}';
  return [for (var h = 1; h <= 254; h++) if ('$h' != p[3]) '$prefix.$h'];
}
