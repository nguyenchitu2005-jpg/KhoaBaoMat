import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/ble/secure_command_sender.dart';
import '../../../core/link/lock_link.dart';
import '../../../core/storage/lock_key_store.dart';
import '../data/ble_lock_data_source.dart';
import '../data/lan_lock_data_source.dart';
import '../data/mqtt_lock_data_source.dart';
import '../domain/lock_status.dart';

enum LinkState { connecting, connected, disconnected }

class DeviceState extends Equatable {
  const DeviceState({
    this.link = LinkState.connecting,
    this.route = LockRoute.ble,
    this.status,
    this.busy = false,
    this.message,
  });

  final LinkState link;
  final LockRoute route; // đang nối qua Bluetooth / Wi-Fi trong nhà / máy chủ trung gian
  final LockStatus? status;
  final bool busy;
  final String? message; // thông báo 1 lần (lỗi / kết quả) để hiện SnackBar

  DeviceState copyWith({LinkState? link, LockRoute? route, LockStatus? status, bool? busy, String? message}) =>
      DeviceState(
        link: link ?? this.link,
        route: route ?? this.route,
        status: status ?? this.status,
        busy: busy ?? this.busy,
        message: message,
      );

  @override
  List<Object?> get props => [link, route, status, busy, message];
}

/// Kết nối 1 khoá, đọc trạng thái, khoá ngay. Mở cửa nằm ở UnlockBloc (cần sinh trắc học).
/// Thứ tự: Wi-Fi trong nhà (nhanh, không cần Bluetooth) → máy chủ trung gian (ở xa) → BLE.
class DeviceCubit extends Cubit<DeviceState> {
  DeviceCubit(this._ble, this._lan, this._remote, this._link, this._keys, this._readStatus, this._lockNow)
      : super(const DeviceState());

  final BleLockDataSource _ble;
  final LanLockDataSource _lan;
  final MqttLockDataSource _remote;
  final LockLink _link;
  final LockKeyStore _keys;
  final ReadLockStatus _readStatus;
  final LockNow _lockNow;
  StreamSubscription<BluetoothConnectionState>? _linkSub;
  String? _lockId;

  Future<void> connect(BluetoothDevice device) async {
    final lockId = _lockId = device.remoteId.str;
    emit(const DeviceState(link: LinkState.connecting));
    // Vừa ghép đôi xong thì đang nối BLE sẵn: dùng luôn BLE
    if (!device.isConnected) {
      final route = await _lan.connect(lockId)
          ? LockRoute.lan
          : await _remote.connect(lockId)
              ? LockRoute.remote
              : null;
      if (route != null) {
        _link.route = route;
        emit(state.copyWith(link: LinkState.connected, route: route));
        await refresh();
        return;
      }
    }
    _link.route = LockRoute.ble;
    try {
      if (!device.isConnected) await _ble.connect(device); // vừa ghép đôi xong thì đã kết nối sẵn
      await _linkSub?.cancel();
      _linkSub = _ble.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && state.link == LinkState.connected) {
          emit(state.copyWith(link: LinkState.disconnected, message: 'Mất kết nối với khoá'));
        }
      });
      emit(state.copyWith(link: LinkState.connected));
      await refresh();
    } catch (e) {
      emit(DeviceState(
        link: LinkState.disconnected,
        message: 'Không kết nối được: $e. Bật Bluetooth và đứng gần khoá, vào cùng Wi-Fi với khoá, '
            'hoặc cài máy chủ trung gian để mở từ xa',
      ));
    }
  }

  Future<void> refresh() => _run(() async {
        final s = await _readStatus(_lockId!);
        emit(state.copyWith(status: s));
      });

  Future<void> lockNow() => _run(() async {
        await _lockNow(_lockId!);
        emit(state.copyWith(message: 'Đã khoá cửa'));
        await refresh();
      });

  /// Xoá khoá AES của khoá này trên điện thoại (phải ghép đôi lại mới mở được).
  Future<void> forget() async {
    await _keys.remove(_lockId!);
    _lan.disconnect();
    _remote.disconnect();
    await _ble.disconnect();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (state.busy || state.link != LinkState.connected) return;
    emit(state.copyWith(busy: true));
    try {
      await action();
    } on LockCommandException catch (e) {
      emit(state.copyWith(message: e.message));
    } on TimeoutException {
      emit(state.copyWith(
          message: 'Khoá không phản hồi – nếu khoá đã bị xoá dữ liệu, hãy "Bỏ ghép đôi" rồi ghép đôi lại'));
    } catch (e) {
      emit(state.copyWith(message: '$e'));
    } finally {
      emit(state.copyWith(busy: false));
    }
  }

  @override
  Future<void> close() async {
    await _linkSub?.cancel();
    _lan.disconnect();
    _remote.disconnect();
    _link.route = LockRoute.ble;
    await _ble.disconnect();
    return super.close();
  }
}
