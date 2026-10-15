import 'package:flutter/material.dart';

import '../../biometric/data/biometric_auth_service.dart';
import '../domain/face_math.dart';
import '../presentation/face_scan_page.dart';
import 'face_store.dart';

/// Xác nhận bằng khuôn mặt do app tự nhận diện (camera trước + FaceNet-512 + kiểm tra nháy mắt).
///
/// Thay cho sinh trắc học của máy ở mọi chỗ gọi [authenticate] một khi đã đăng ký khuôn mặt.
/// Chưa đăng ký thì vẫn dùng sinh trắc học của máy như trước.
class FaceAuthService extends BiometricAuthService {
  FaceAuthService(this._store, this._navigator, {this.level = kDefaultFaceSecurityLevel});

  final FaceStore _store;
  final GlobalKey<NavigatorState> _navigator;

  /// Mức an toàn = ngưỡng khoảng cách. Chặt hơn thì ít nhận nhầm nhưng dễ từ chối chính chủ.
  final FaceSecurityLevel level;

  Future<bool> get enrolled async => await _store.read() != null;

  @override
  Future<BiometricOutcome> authenticate(String reason) async {
    final reference = await _store.read();
    if (reference == null) return super.authenticate(reason);
    final shots = await _scan(reason, 2);
    if (shots == null) return BiometricOutcome.canceled;
    return matchDistance(reference, shots) < level.threshold ? BiometricOutcome.success : BiometricOutcome.faceMismatch;
  }

  /// Đăng ký (hoặc đăng ký lại) khuôn mặt. Trả về null nếu xong, hoặc lý do thất bại.
  /// Bắt buộc qua sinh trắc học của máy trước: người cầm máy đã mở khoá không tự thêm mặt mình được.
  Future<String?> enroll() async {
    final bio = await super.authenticate('Xác thực để đăng ký khuôn mặt');
    if (bio != BiometricOutcome.success) return bio.message;
    final shots = await _scan('Đăng ký khuôn mặt', 5);
    if (shots == null) return 'Đã huỷ đăng ký khuôn mặt';
    await _store.save(averageEmbeddings(shots));
    return null;
  }

  /// Xoá khuôn mặt đã đăng ký; app quay lại dùng sinh trắc học của máy.
  Future<String?> remove() async {
    final bio = await super.authenticate('Xác thực để xoá khuôn mặt');
    if (bio != BiometricOutcome.success) return bio.message;
    await _store.clear();
    return null;
  }

  Future<List<List<double>>?> _scan(String title, int shots) async {
    final navigator = _navigator.currentState;
    if (navigator == null) return null;
    return navigator.push<List<List<double>>>(
      MaterialPageRoute(builder: (_) => FaceScanScreen(title: title, shots: shots), fullscreenDialog: true),
    );
  }
}
