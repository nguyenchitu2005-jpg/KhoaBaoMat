import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/ble/secure_command_sender.dart';
import '../../../core/storage/lock_key_store.dart';
import '../data/ble_lock_data_source.dart';
import '../domain/lock_status.dart';

enum LinkState { connecting, connected, disconnected }

class DeviceState extends Equatable {
  const DeviceState({this.link = LinkState.connecting, this.status, this.busy = false, this.message});

  final LinkState link;
  final LockStatus? status;
  final bool busy;
  final String? message; // thông báo 1 lần (lỗi / kết quả) để hiện SnackBar

  DeviceState copyWith({LinkState? link, LockStatus? status, bool? busy, String? message}) =>
      DeviceState(link: link ?? this.link, status: status ?? this.status, busy: busy ?? this.busy, message: message);

  @override
  List<Object?> get props => [link, status, busy, message];
}

/// Kết nối 1 khoá, đọc trạng thái, khoá ngay. Mở cửa nằm ở UnlockBloc (cần sinh trắc học).
class DeviceCubit extends Cubit<DeviceState> {
  DeviceCubit(this._ble, this._keys, this._readStatus, this._lockNow) : super(const DeviceState());

  final BleLockDataSource _ble;
  final LockKeyStore _keys;
  final ReadLockStatus _readStatus;
  final LockNow _lockNow;
  StreamSubscription<BluetoothConnectionState>? _linkSub;
  String? _lockId;

  Future<void> connect(BluetoothDevice device) async {
    _lockId = device.remoteId.str;
    emit(const DeviceState(link: LinkState.connecting));
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
      emit(DeviceState(link: LinkState.disconnected, message: 'Không kết nối được: $e'));
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
    await _ble.disconnect();
    return super.close();
  }
}
