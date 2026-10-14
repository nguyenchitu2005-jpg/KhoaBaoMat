/// Các bước kiểm tra người thật (chống dùng ảnh tĩnh): nhìn thẳng, mở mắt,
/// nháy mắt, rồi mở mắt lại.
enum LivenessStep {
  noFace,
  multipleFaces,
  lookStraight,
  openEyes,
  blink,
  reopenEyes,
  passed,
}

/// Máy trạng thái nhận kết quả ML Kit của từng khung hình camera.
/// Thuần Dart, không phụ thuộc plugin nên kiểm thử được.
class LivenessChecker {
  static const double openThreshold = 0.7;
  static const double closedThreshold = 0.3;
  static const double maxHeadAngle = 20;

  LivenessStep _progress = LivenessStep.openEyes;

  LivenessStep get progress => _progress;

  void reset() => _progress = LivenessStep.openEyes;

  /// [leftEye]/[rightEye]: xác suất mắt đang mở (0..1), [headY]: góc quay đầu trái/phải.
  /// Trả về bước cần hiển thị cho người dùng.
  LivenessStep update({
    required int faceCount,
    double? leftEye,
    double? rightEye,
    double? headY,
  }) {
    if (_progress == LivenessStep.passed) return _progress;
    if (faceCount == 0) {
      reset();
      return LivenessStep.noFace;
    }
    if (faceCount > 1) {
      reset();
      return LivenessStep.multipleFaces;
    }
    if (headY != null && headY.abs() > maxHeadAngle) {
      return LivenessStep.lookStraight;
    }
    if (leftEye == null || rightEye == null) return _progress;

    final open = leftEye > openThreshold && rightEye > openThreshold;
    final closed = leftEye < closedThreshold && rightEye < closedThreshold;
    switch (_progress) {
      case LivenessStep.openEyes:
        if (open) _progress = LivenessStep.blink;
      case LivenessStep.blink:
        if (closed) _progress = LivenessStep.reopenEyes;
      case LivenessStep.reopenEyes:
        if (open) _progress = LivenessStep.passed;
      default:
        break;
    }
    return _progress;
  }

  static String message(LivenessStep step) {
    switch (step) {
      case LivenessStep.noFace:
        return 'Đưa khuôn mặt vào giữa khung hình';
      case LivenessStep.multipleFaces:
        return 'Chỉ được có một khuôn mặt trong khung hình';
      case LivenessStep.lookStraight:
        return 'Hãy nhìn thẳng vào camera';
      case LivenessStep.openEyes:
        return 'Mở mắt và nhìn vào camera';
      case LivenessStep.blink:
        return 'Hãy nháy mắt';
      case LivenessStep.reopenEyes:
        return 'Mở mắt ra';
      case LivenessStep.passed:
        return 'Giữ yên… đang chụp';
    }
  }
}
