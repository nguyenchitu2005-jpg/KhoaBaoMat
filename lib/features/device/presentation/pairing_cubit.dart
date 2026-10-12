import 'package:equatable/equatable.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../data/ble_lock_data_source.dart';
import '../domain/pair_lock.dart';

enum PairingStep { instructions, connecting, waitingForCode, done, failed }

class PairingState extends Equatable {
  const PairingState({this.step = PairingStep.instructions, this.code, this.error});

  final PairingStep step;
  final String? code; // mã 6 số để người dùng gõ trên bàn phím của khoá
  final String? error;

  @override
  List<Object?> get props => [step, code, error];
}

/// Điều phối 1 lần ghép đôi: kết nối → trao khoá → hiện mã → chờ xác nhận → lưu khoá.
class PairingCubit extends Cubit<PairingState> {
  PairingCubit(this._ble, this._pair) : super(const PairingState());

  final BleLockDataSource _ble;
  final PairLock _pair;

  Future<void> start(BluetoothDevice device) async {
    if (state.step == PairingStep.connecting || state.step == PairingStep.waitingForCode) return;
    emit(const PairingState(step: PairingStep.connecting));
    try {
      if (!device.isConnected) await _ble.connect(device);
      final session = await _pair.begin();
      emit(PairingState(step: PairingStep.waitingForCode, code: session.confirmCode));
      await _pair.waitConfirmed(device.remoteId.str, session);
      emit(const PairingState(step: PairingStep.done));
    } on PairingException catch (e) {
      emit(PairingState(step: PairingStep.failed, error: e.message));
    } on BleException catch (e) {
      emit(PairingState(step: PairingStep.failed, error: e.message));
    } catch (e) {
      emit(PairingState(step: PairingStep.failed, error: 'Không ghép đôi được: $e'));
    }
  }
}
