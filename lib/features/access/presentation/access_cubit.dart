import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/ble/secure_command_sender.dart';
import '../domain/access_admin.dart';

class AccessState extends Equatable {
  const AccessState({this.list, this.phones = const [], this.busy = false, this.prompt, this.message});

  final AccessList? list; // null = chưa tải được
  final List<PhoneEntry> phones; // điện thoại đã ghép đôi
  final bool busy;
  final String? prompt; // hướng dẫn khi đang đăng ký ("Đưa thẻ lại gần đầu đọc…")
  final String? message; // thông báo 1 lần để hiện SnackBar

  @override
  List<Object?> get props => [list, phones, busy, prompt, message];
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

  void _prompt(String text) {
    if (!isClosed) emit(AccessState(list: state.list, phones: state.phones, busy: true, prompt: text));
  }

  /// Chạy 1 lệnh rồi tải lại danh sách. [action] trả về thông báo thành công (hoặc null).
  Future<void> _run(Future<String?> Function() action, {String? prompt}) async {
    if (state.busy) return;
    emit(AccessState(list: state.list, phones: state.phones, busy: true, prompt: prompt));
    var list = state.list;
    var phones = state.phones;
    String? message;
    try {
      message = await action();
      list = await _admin.list(_lockId);
      phones = await _admin.listPhones(_lockId);
    } on LockCommandException catch (e) {
      message = e.message;
    } on TimeoutException {
      message = 'Khoá không phản hồi – hãy lại gần khoá hơn';
    } catch (e) {
      message = '$e';
    }
    if (!isClosed) emit(AccessState(list: list, phones: phones, message: message));
  }
}
