import 'package:khoabaomat/features/face/domain/liveness_checker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LivenessChecker checker;

  setUp(() => checker = LivenessChecker());

  LivenessStep frame({int faces = 1, double eyes = 0.9, double headY = 0}) =>
      checker.update(
        faceCount: faces,
        leftEye: eyes,
        rightEye: eyes,
        headY: headY,
      );

  test('mở mắt -> nháy mắt -> mở mắt thì qua bước kiểm tra', () {
    expect(frame(eyes: 0.9), LivenessStep.blink);
    expect(frame(eyes: 0.1), LivenessStep.reopenEyes);
    expect(frame(eyes: 0.9), LivenessStep.passed);
  });

  test('ảnh tĩnh luôn mở mắt thì không bao giờ qua', () {
    for (var i = 0; i < 50; i++) {
      expect(frame(eyes: 0.95), LivenessStep.blink);
    }
  });

  test('mất khuôn mặt hoặc có nhiều khuôn mặt thì làm lại từ đầu', () {
    frame(eyes: 0.9);
    frame(eyes: 0.1);
    expect(frame(faces: 0), LivenessStep.noFace);
    expect(checker.progress, LivenessStep.openEyes);

    frame(eyes: 0.9);
    expect(frame(faces: 2), LivenessStep.multipleFaces);
    expect(checker.progress, LivenessStep.openEyes);
  });

  test('quay đầu quá nhiều thì yêu cầu nhìn thẳng, giữ nguyên tiến độ', () {
    frame(eyes: 0.9);
    expect(frame(eyes: 0.1, headY: 35), LivenessStep.lookStraight);
    expect(checker.progress, LivenessStep.blink);
  });

  test('mắt hé (giữa 2 ngưỡng) không được tính là nháy', () {
    frame(eyes: 0.9);
    expect(frame(eyes: 0.5), LivenessStep.blink);
  });
}
