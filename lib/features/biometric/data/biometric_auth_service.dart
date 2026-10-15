import 'package:local_auth/local_auth.dart';

enum BiometricOutcome {
  success('Xác thực thành công'),
  canceled('Đã huỷ xác thực'),
  notAvailable('Máy không hỗ trợ sinh trắc học'),
  notEnrolled('Chưa cài vân tay / khuôn mặt trong Cài đặt của máy'),
  lockedOut('Sai quá nhiều lần, sinh trắc học tạm bị khoá'),
  failed('Xác thực thất bại'),
  faceMismatch('Khuôn mặt không khớp – nhìn thẳng camera ở nơi đủ sáng rồi thử lại');

  const BiometricOutcome(this.message);
  final String message;
}

/// Xác thực bằng sinh trắc học của hệ điều hành (Face ID / Touch ID / Android BiometricPrompt)
/// qua local_auth 3.x.
class BiometricAuthService {
  BiometricAuthService([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// Có dùng được sinh trắc học "mạnh" không. Trên Android, mở khoá khuôn mặt của nhiều máy
  /// chỉ là loại weak (chụp 2D) – không đủ tin cậy để mở cửa nên bị loại.
  Future<bool> hasStrongBiometric() async {
    if (!await _auth.isDeviceSupported()) return false;
    final types = await _auth.getAvailableBiometrics();
    return types.contains(BiometricType.strong) || // Android lớp 3
        types.contains(BiometricType.face) || // iOS Face ID
        types.contains(BiometricType.fingerprint); // iOS Touch ID / Android cũ
  }

  Future<BiometricOutcome> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true, // không cho dùng mã PIN màn hình khoá thay thế
        persistAcrossBackgrounding: true, // không huỷ khi app bị đẩy xuống nền giữa chừng
      );
      return ok ? BiometricOutcome.success : BiometricOutcome.failed;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.userRequestedFallback =>
          BiometricOutcome.canceled,
        LocalAuthExceptionCode.noBiometricHardware ||
        LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable =>
          BiometricOutcome.notAvailable,
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noCredentialsSet =>
          BiometricOutcome.notEnrolled,
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout =>
          BiometricOutcome.lockedOut,
        _ => BiometricOutcome.failed,
      };
    }
  }
}
