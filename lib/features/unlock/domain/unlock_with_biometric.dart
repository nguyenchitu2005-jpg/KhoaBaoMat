import 'dart:async';

import 'package:cryptography/cryptography.dart';

import '../../../core/ble/lock_protocol.dart';
import '../../../core/ble/secure_command_sender.dart';
import '../../../core/storage/lock_key_store.dart';
import '../../biometric/data/biometric_auth_service.dart';
import '../../device/data/ble_lock_data_source.dart';

sealed class UnlockResult {
  const UnlockResult();
}

final class UnlockSuccess extends UnlockResult {
  const UnlockSuccess();
}

final class UnlockFailure extends UnlockResult {
  const UnlockFailure(this.reason);
  final String reason;
}

enum UnlockStep { authenticating, sending }

/// Use case: xác thực sinh trắc trên điện thoại → gửi lệnh UNLOCK đã mã hoá.
class UnlockWithBiometric {
  UnlockWithBiometric(this._biometric, this._keys, this._sender);

  final BiometricAuthService _biometric;
  final LockKeyStore _keys;
  final SecureCommandSender _sender;

  Future<UnlockResult> call(String lockId, {void Function(UnlockStep step)? onStep}) async {
    // 1. Xác thực người dùng trên điện thoại
    onStep?.call(UnlockStep.authenticating);
    final bio = await _biometric.authenticate('Xác thực để mở cửa');
    if (bio != BiometricOutcome.success) return UnlockFailure(bio.message);

    // 2. Lấy khoá AES riêng của điện thoại (chỉ đọc SAU khi xác thực thành công)
    final cred = await _keys.read(lockId);
    if (cred == null) return const UnlockFailure('Điện thoại chưa ghép đôi với khoá này');

    // 3. Gửi lệnh mở (challenge → AES-GCM → kiểm tra phản hồi)
    try {
      onStep?.call(UnlockStep.sending);
      await _sender.send(cred, LockCmd.unlock);
      return const UnlockSuccess();
    } on LockCommandException catch (e) {
      return UnlockFailure(e.message);
    } on TimeoutException {
      return const UnlockFailure('Khoá không phản hồi – hãy lại gần cửa hơn');
    } on SecretBoxAuthenticationError {
      return const UnlockFailure('Phản hồi bị sửa đổi hoặc sai khoá – đã từ chối');
    } on BleException catch (e) {
      return UnlockFailure(e.message);
    } on FormatException catch (e) {
      return UnlockFailure(e.message);
    }
  }
}
