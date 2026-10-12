import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../../core/ble/lock_protocol.dart';

class BleException implements Exception {
  const BleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Lớp dữ liệu BLE: quét, kết nối, gửi gói và nhận gói notify từ khoá.
/// Không biết gì về mã hoá – chỉ chuyển byte.
class BleLockDataSource {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _command;
  final _frames = StreamController<Uint8List>.broadcast();

  /// Mọi gói khoá gửi về qua characteristic Event.
  Stream<Uint8List> get frames => _frames.stream;

  Stream<BluetoothConnectionState> get connectionState =>
      _device?.connectionState ?? Stream.value(BluetoothConnectionState.disconnected);

  /// Quét khoá ở gần, chỉ lấy thiết bị quảng bá đúng service UUID của khoá.
  Future<Stream<List<ScanResult>>> scan({Duration timeout = const Duration(seconds: 10)}) async {
    final state = await FlutterBluePlus.adapterState
        .firstWhere((s) => s != BluetoothAdapterState.unknown);
    if (state != BluetoothAdapterState.on) {
      throw const BleException('Bluetooth đang tắt');
    }
    await FlutterBluePlus.startScan(withServices: [LockUuids.service], timeout: timeout);
    // Lọc lại phía Dart: bộ lọc của hệ điều hành không đáng tin trên mọi nền tảng
    // (Windows trả về cả thiết bị không quảng bá UUID này).
    return FlutterBluePlus.scanResults.map(
      (list) => list.where((r) => r.advertisementData.serviceUuids.contains(LockUuids.service)).toList(),
    );
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  Future<void> connect(BluetoothDevice device) async {
    // flutter_blue_plus 2.x bắt buộc khai báo giấy phép; đồ án học tập dùng License.nonprofit.
    await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 15), mtu: 247);

    final services = await device.discoverServices();
    final service = services.where((s) => s.uuid == LockUuids.service).firstOrNull;
    if (service == null) {
      await device.disconnect();
      throw const BleException('Thiết bị này không phải khoá Khoabaomat');
    }
    BluetoothCharacteristic find(Guid uuid) => service.characteristics.firstWhere((c) => c.uuid == uuid);

    final event = find(LockUuids.event);
    final sub = event.onValueReceived.listen((v) => _frames.add(Uint8List.fromList(v)));
    device.cancelWhenDisconnected(sub); // tự huỷ khi mất kết nối, tránh rò rỉ
    await event.setNotifyValue(true);

    _command = find(LockUuids.command);
    _device = device;
  }

  Future<void> disconnect() async {
    await _device?.disconnect();
    _device = null;
    _command = null;
  }

  Future<void> write(List<int> frame) async {
    final c = _command;
    if (c == null) throw const BleException('Chưa kết nối khoá');
    await c.write(frame); // write có phản hồi: biết chắc khoá đã nhận
  }

  /// Gửi 1 gói rồi chờ gói trả về đầu tiên có byte đầu thuộc [replyKinds].
  Future<Uint8List> request(
    List<int> frame, {
    required Set<int> replyKinds,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // Đăng ký nghe TRƯỚC khi ghi để không lỡ gói trả về quá nhanh.
    final reply = frames.firstWhere((f) => f.isNotEmpty && replyKinds.contains(f[0])).timeout(timeout);
    try {
      await write(frame);
    } catch (_) {
      reply.ignore();
      rethrow;
    }
    return reply;
  }
}
