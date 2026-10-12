import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/ble/secure_command_sender.dart';
import '../domain/access_admin.dart';

class AccessState extends Equatable {
  const AccessState({this.list, this.busy = false, this.prompt, this.message});

  final AccessList? list; // null = chưa tải được
  final bool busy;
  final String? prompt; // hướng dẫn khi đang đăng ký ("Đưa thẻ lại gần đầu đọc…")
  final String? message; // thông báo 1 lần để hiện SnackBar

  @override
  List<Object?> get props => [list, busy, prompt, message];
}

/// Quản lý thẻ RFID, vân tay và mã PIN của 1 khoá (chỉ admin).
class AccessCubit extends Cubit<AccessState> {
  AccessCubit(this._admin, this._lockId) : super(const AccessState());

  final AccessAdmin _admin;
  final String _lockId;

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

  void _prompt(String text) {
    if (!isClosed) emit(AccessState(list: state.list, busy: true, prompt: text));
  }

  /// Chạy 1 lệnh rồi tải lại danh sách. [action] trả về thông báo thành công (hoặc null).
  Future<void> _run(Future<String?> Function() action, {String? prompt}) async {
    if (state.busy) return;
    emit(AccessState(list: state.list, busy: true, prompt: prompt));
    var list = state.list;
    String? message;
    try {
      message = await action();
      list = await _admin.list(_lockId);
    } on LockCommandException catch (e) {
      message = e.message;
    } on TimeoutException {
      message = 'Khoá không phản hồi – hãy lại gần khoá hơn';
    } catch (e) {
      message = '$e';
    }
    if (!isClosed) emit(AccessState(list: list, message: message));
  }
}
