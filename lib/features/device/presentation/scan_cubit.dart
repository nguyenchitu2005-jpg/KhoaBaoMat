import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../data/ble_lock_data_source.dart';

class ScanState extends Equatable {
  const ScanState({this.scanning = false, this.results = const [], this.error});

  final bool scanning;
  final List<ScanResult> results;
  final String? error;

  @override
  List<Object?> get props => [scanning, results, error];
}

/// Quét các khoá ở gần (lọc theo service UUID), tự dừng sau 10 giây.
class ScanCubit extends Cubit<ScanState> {
  ScanCubit(this._ble) : super(const ScanState());

  final BleLockDataSource _ble;
  StreamSubscription<List<ScanResult>>? _resultsSub;
  StreamSubscription<bool>? _scanningSub;

  Future<void> start() async {
    if (state.scanning) return;
    // flutter_blue_plus tự xin quyền Bluetooth (Android 12+) / vị trí (Android ≤ 11) khi quét.
    try {
      emit(const ScanState(scanning: true));
      final results = await _ble.scan(timeout: const Duration(seconds: 10));
      await _resultsSub?.cancel();
      _resultsSub = results.listen((r) {
        final sorted = [...r]..sort((a, b) => b.rssi.compareTo(a.rssi));
        emit(ScanState(scanning: state.scanning, results: sorted));
      });
      await _scanningSub?.cancel();
      _scanningSub = FlutterBluePlus.isScanning.listen((s) {
        if (!s) emit(ScanState(results: state.results));
      });
    } on BleException catch (e) {
      emit(ScanState(error: e.message));
    } on FlutterBluePlusException catch (e) {
      final denied = (e.description ?? '').toLowerCase().contains('permission');
      emit(ScanState(error: denied ? 'Cần cấp quyền "Thiết bị ở gần" để tìm khoá' : 'Không quét được: ${e.description}'));
    } catch (e) {
      emit(ScanState(error: 'Không quét được: $e'));
    }
  }

  Future<void> stop() => _ble.stopScan();

  @override
  Future<void> close() async {
    await _resultsSub?.cancel();
    await _scanningSub?.cancel();
    await _ble.stopScan();
    return super.close();
  }
}
