import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/ble/lock_protocol.dart';
import '../../../core/ble/secure_command_sender.dart';
import '../../device/data/lan_lock_data_source.dart';
import '../../device/data/mqtt_lock_data_source.dart';
import '../domain/access_admin.dart';

class AccessState extends Equatable {
  const AccessState({
    this.list,
    this.phones = const [],
    this.wifi,
    this.mqtt,
    this.remote,
    this.busy = false,
    this.prompt,
    this.message,
  });

  final AccessList? list; // null = chưa tải được
  final List<PhoneEntry> phones; // điện thoại đã ghép đôi
  final WifiStatus? wifi; // null = chưa đọc được (firmware cũ chưa có Wi-Fi)
  final MqttStatus? mqtt; // khoá có đang vào máy chủ trung gian; null = firmware cũ chưa có
  final MqttSettings? remote; // máy chủ trung gian đã lưu trên điện thoại này
  final bool busy;
  final String? prompt; // hướng dẫn khi đang đăng ký ("Đưa thẻ lại gần đầu đọc…")
  final String? message; // thông báo 1 lần để hiện SnackBar

  /// Giữ dữ liệu đã tải, đổi trạng thái bận / thông báo.
  AccessState next({bool busy = false, String? prompt, String? message}) => AccessState(
        list: list,
        phones: phones,
        wifi: wifi,
        mqtt: mqtt,
        remote: remote,
        busy: busy,
        prompt: prompt,
        message: message,
      );

  @override
  List<Object?> get props => [list, phones, wifi, mqtt, remote, busy, prompt, message];
}

/// Quản lý thẻ RFID, vân tay và mã PIN của 1 khoá (chỉ admin).
class AccessCubit extends Cubit<AccessState> {
  AccessCubit(this._admin, this._lockId, [this._lan, this._remote]) : super(const AccessState());

  final AccessAdmin _admin;
  final String _lockId;
  final LanLockDataSource? _lan; // ghi nhớ IP khoá để lần sau mở qua Wi-Fi trong nhà
  final MqttLockDataSource? _remote; // lưu cấu hình máy chủ trung gian trên điện thoại

  /// Cài máy chủ trung gian cho khoá và điện thoại này (cùng 1 tài khoản). null = tắt cả hai.
  Future<void> setRemote(MqttSettings? s) => _run(() async {
        final denied = await _deniedOverRemote(() => _admin.setMqtt(_lockId, s));
        if (denied != null) return denied;
        await _remote?.saveSettings(s); // khoá nhận rồi mới lưu trên máy
        if (s == null) return 'Đã tắt điều khiển từ xa';
        _prompt('Khoá đang vào máy chủ ${s.host}…');
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(seconds: 2));
          final m = await _admin.mqttStatus(_lockId);
          if (m.state == MqttLinkState.connected) return 'Khoá đã vào máy chủ – giờ mở được từ xa';
          if (m.state == MqttLinkState.error) {
            return 'Khoá không vào được máy chủ – kiểm tra địa chỉ, cổng, tài khoản và mật khẩu';
          }
        }
        return 'Khoá vẫn đang kết nối máy chủ – bấm Làm mới sau ít giây';
      }, prompt: 'Đang gửi cấu hình máy chủ cho khoá…');

  /// Khoá không cho đổi Wi-Fi / máy chủ qua chính đường từ xa (nhập sai là mất đường điều khiển khi ở xa).
  Future<String?> _deniedOverRemote(Future<void> Function() send) async {
    try {
      await send();
      return null;
    } on LockCommandException catch (e) {
      if (e.result != LockResult.denied) rethrow;
      return 'Khoá chỉ cho đổi Wi-Fi / máy chủ khi ở nhà (qua Wi-Fi trong nhà hoặc Bluetooth)';
    }
  }

  Future<void> load() => _run(() async => null);

  Future<void> enrollCard() => _run(
        () async => 'Đã thêm thẻ ${(await _admin.enrollCard(_lockId)).uid}',
        prompt: 'Đưa thẻ mới lại gần đầu đọc của khoá (15 giây)…',
      );

  Future<void> deleteCard(int index) => _run(() async {
        await _admin.deleteCard(_lockId, index);
        return 'Đã xoá thẻ';
      });

  Future<void> enrollFinger() => _run(
        () async {
          final id = await _admin.enrollFinger(_lockId, onProgress: (step) {
            _prompt(step == 1 ? 'Nhấc ngón tay ra…' : 'Đặt lại cùng ngón tay lần 2…');
          });
          return 'Đã thêm vân tay #$id';
        },
        prompt: 'Đặt ngón tay lên cảm biến của khoá…',
      );

  Future<void> deleteFinger(int id) => _run(() async {
        await _admin.deleteFinger(_lockId, id);
        return 'Đã xoá vân tay #$id';
      });

  /// [pin] rỗng = tắt mở bằng PIN.
  Future<void> setPin(String pin) => _run(() async {
        await _admin.setPin(_lockId, pin);
        return pin.isEmpty ? 'Đã tắt mã PIN' : 'Đã đặt mã PIN mới';
      });

  /// Mã khách có hạn. [pin] rỗng = xoá.
  Future<void> setGuestPin(String pin, [Duration validFor = Duration.zero]) => _run(() async {
        await _admin.setGuestPin(_lockId, pin, validFor: validFor);
        return pin.isEmpty ? 'Đã xoá mã khách' : 'Đã đặt mã khách';
      });

  /// Thu hồi 1 điện thoại khác: máy đó không mở được khoá nữa cho đến khi ghép đôi lại.
  Future<void> revokePhone(int keyId) => _run(() async {
        await _admin.revokePhone(_lockId, keyId);
        return 'Đã thu hồi điện thoại #$keyId';
      });

  /// Gửi Wi-Fi cho khoá rồi đợi khoá vào mạng (khoá báo lỗi sau ~20 giây nếu không vào được).
  /// [ssid] rỗng = quên Wi-Fi.
  Future<void> setWifi(String ssid, String password) => _run(() async {
        final denied = await _deniedOverRemote(() => _admin.setWifi(_lockId, ssid, password));
        if (denied != null) return denied;
        if (ssid.isEmpty) return 'Đã quên Wi-Fi';
        _prompt('Khoá đang vào Wi-Fi "$ssid"…');
        for (var i = 0; i < 12; i++) {
          await Future<void>.delayed(const Duration(seconds: 2));
          final w = await _admin.wifiStatus(_lockId);
          if (w.state == WifiState.connected) return 'Khoá đã vào Wi-Fi "$ssid"';
          if (w.state == WifiState.failed) return 'Khoá không vào được "$ssid" – kiểm tra mật khẩu, mạng phải là 2,4 GHz';
        }
        return 'Khoá vẫn đang kết nối "$ssid" – bấm Làm mới sau ít giây';
      }, prompt: 'Đang gửi Wi-Fi cho khoá…');

  void _prompt(String text) {
    if (!isClosed) emit(state.next(busy: true, prompt: text));
  }

  /// Chạy 1 lệnh rồi tải lại danh sách. [action] trả về thông báo thành công (hoặc null).
  Future<void> _run(Future<String?> Function() action, {String? prompt}) async {
    if (state.busy) return;
    emit(state.next(busy: true, prompt: prompt));
    var loaded = state;
    String? message;
    try {
      message = await action();
      loaded = AccessState(
        list: await _admin.list(_lockId),
        phones: await _admin.listPhones(_lockId),
        wifi: await _wifiOrNull(),
        mqtt: await _mqttOrNull(),
        remote: await _remote?.settings(),
      );
    } on LockCommandException catch (e) {
      message = e.message;
    } on TimeoutException {
      message = 'Khoá không phản hồi – hãy lại gần khoá hơn';
    } catch (e) {
      message = '$e';
    }
    if (!isClosed) emit(loaded.next(message: message));
  }

  /// Firmware cũ chưa có điều khiển từ xa (trả "lệnh lạ") thì vẫn hiện phần còn lại của trang.
  Future<MqttStatus?> _mqttOrNull() async {
    try {
      return await _admin.mqttStatus(_lockId);
    } on LockCommandException {
      return null;
    }
  }

  /// Firmware cũ chưa có lệnh Wi-Fi (trả "lệnh lạ") thì vẫn hiện phần còn lại của trang.
  Future<WifiStatus?> _wifiOrNull() async {
    try {
      final w = await _admin.wifiStatus(_lockId);
      if (w.state == WifiState.connected) await _lan?.rememberIp(_lockId, w.ip);
      return w;
    } on LockCommandException {
      return null;
    }
  }
}
