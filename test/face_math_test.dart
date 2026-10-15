import 'dart:math';
import 'dart:typed_data';

import 'package:khoabaomat/features/face/domain/face_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('l2Normalize đưa vector về độ dài 1', () {
    final v = l2Normalize([3, 4]);
    expect(v[0], closeTo(0.6, 1e-9));
    expect(v[1], closeTo(0.8, 1e-9));
  });

  test('euclideanDistance: cùng vector = 0, vector vuông góc = căn 2', () {
    expect(euclideanDistance([1, 0], [1, 0]), 0);
    expect(euclideanDistance([1, 0], [0, 1]), closeTo(1.41421356, 1e-6));
    expect(() => euclideanDistance([1], [1, 2]), throwsArgumentError);
  });

  test('averageEmbeddings lấy trung bình rồi chuẩn hoá', () {
    final avg = averageEmbeddings([
      [1, 0],
      [0, 1],
    ]);
    expect(avg[0], closeTo(0.70710678, 1e-6));
    expect(avg[1], closeTo(0.70710678, 1e-6));
  });

  test('cropFace cắt vùng vuông và không vượt ra ngoài ảnh', () {
    final image = img.Image(width: 200, height: 100);
    // Khuôn mặt sát mép phải: vùng cắt phải bị dồn vào trong ảnh.
    final face = cropFace(image, left: 170, top: 10, width: 40, height: 60);
    expect(face.width, face.height);
    expect(face.width, 78); // max(40, 60) * kFaceCropScale (1.3)
  });

  test('imageToModelInput chuẩn hoá theo từng ảnh (FaceNet), thứ tự RGB', () {
    final image = img.Image(width: 1, height: 1)
      ..setPixelRgb(0, 0, 0, 128, 255);
    final input = imageToModelInput(image);
    expect(input.length, 3);
    // Trung bình 0, độ lệch chuẩn 1; thứ tự R < G < B giữ nguyên.
    final mean = input.reduce((a, b) => a + b) / 3;
    final variance =
        input.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / 3;
    expect(mean, closeTo(0, 1e-5));
    expect(variance, closeTo(1, 1e-4));
    expect(input[0] < input[1] && input[1] < input[2], isTrue);

    // Cùng khuôn mặt nhưng sáng hơn / tương phản khác → cùng đầu vào.
    final brighter = img.Image(
      width: 1,
      height: 1,
    )..setPixelRgb(0, 0, 50, 114, 177); // = 50 + 0.5 * (0, 128, 255) (làm tròn)
    final input2 = imageToModelInput(brighter);
    for (var i = 0; i < 3; i++) {
      expect(input2[i], closeTo(input[i], 0.02));
    }
  });

  test(
    'Model hiện tại: vector 512 chiều; vector cũ 192 chiều bị coi là cũ',
    () {
      expect(
        isCurrentFaceEmbedding(List.filled(kFaceEmbeddingLength, 0.0)),
        isTrue,
      );
      expect(isCurrentFaceEmbedding(List.filled(192, 0.0)), isFalse);
    },
  );

  test('matchDistance lấy ảnh khớp nhất', () {
    final samples = [
      [0.0, 1.0],
      [1.0, 0.0],
    ];
    expect(distancesTo([1, 0], samples), [closeTo(sqrt2, 1e-9), 0]);
    expect(matchDistance([1, 0], samples), 0);
    expect(() => matchDistance([1, 0], []), throwsArgumentError);
  });

  test('Mức an toàn: chặt dần, mặc định chặt hơn bản cũ (0.95)', () {
    final thresholds = FaceSecurityLevel.values.map((l) => l.threshold);
    expect(
      thresholds,
      orderedEquals([...thresholds]..sort((a, b) => b.compareTo(a))),
    );
    // Bản cũ 0.95: người giống nhất lọt ~21%/lần trên LFW.
    expect(FaceSecurityLevel.values.first.threshold, lessThan(0.95));
    expect(kDefaultFaceSecurityLevel.threshold, lessThanOrEqualTo(0.75));
    expect(FaceSecurityLevel.fromName('veryHigh'), FaceSecurityLevel.veryHigh);
    expect(FaceSecurityLevel.fromName(null), kDefaultFaceSecurityLevel);
    expect(FaceSecurityLevel.fromName('xyz'), kDefaultFaceSecurityLevel);
  });

  test('eyeLineAngle không phụ thuộc thứ tự 2 mắt', () {
    expect(eyeLineAngle(0, 0, 10, 10), closeTo(45, 1e-9));
    expect(eyeLineAngle(10, 10, 0, 0), closeTo(45, 1e-9));
    expect(eyeLineAngle(0, 10, 10, 0), closeTo(-45, 1e-9));
    expect(eyeLineAngle(0, 5, 10, 5), 0);
  });

  test('faceQualityProblem loại ảnh quay đầu, ngẩng/cúi, nhắm mắt', () {
    expect(
      faceQualityProblem(
        headY: 5,
        headX: -5,
        leftEyeOpen: 0.9,
        rightEyeOpen: 0.8,
      ),
      isNull,
    );
    expect(faceQualityProblem(), isNull);
    expect(faceQualityProblem(headY: 25), contains('quay đầu'));
    expect(faceQualityProblem(headX: -20), contains('ngẩng'));
    expect(
      faceQualityProblem(leftEyeOpen: 0.9, rightEyeOpen: 0.1),
      contains('mở mắt'),
    );
    expect(
      faceQualityProblem(faceWidth: 100, imageWidth: 720),
      contains('lại gần'),
    );
    expect(faceQualityProblem(faceWidth: 300, imageWidth: 720), isNull);
  });

  test('alignAndCropFace xoay để 2 mắt nằm ngang', () {
    // Ảnh trắng có 2 "mắt" đen, đường nối nghiêng ~26.6°.
    final image = img.Image(width: 300, height: 300)
      ..clear(img.ColorRgb8(255, 255, 255));
    void dot(int cx, int cy) => img.fillRect(
      image,
      x1: cx - 4,
      y1: cy - 4,
      x2: cx + 4,
      y2: cy + 4,
      color: img.ColorRgb8(0, 0, 0),
    );
    dot(110, 130);
    dot(190, 170);
    final roll = eyeLineAngle(110, 130, 190, 170);

    final face = alignAndCropFace(
      image,
      left: 70,
      top: 70,
      width: 160,
      height: 160,
      rollDegrees: roll,
    );

    // Tìm trọng tâm điểm đen ở nửa trái và nửa phải ảnh kết quả.
    ({double x, double y}) centroid(int fromX, int toX) {
      var sx = 0.0, sy = 0.0, n = 0;
      for (var y = 0; y < face.height; y++) {
        for (var x = fromX; x < toX; x++) {
          if (face.getPixel(x, y).r < 100) {
            sx += x;
            sy += y;
            n++;
          }
        }
      }
      return (x: sx / n, y: sy / n);
    }

    final left = centroid(0, face.width ~/ 2);
    final right = centroid(face.width ~/ 2, face.width);
    expect((left.y - right.y).abs(), lessThan(2)); // 2 mắt cùng độ cao
    // Khoảng cách 2 mắt giữ nguyên (~89px), khuôn mặt vẫn nằm giữa vùng cắt.
    expect(right.x - left.x, closeTo(89.4, 2));
    expect((left.x + right.x) / 2, closeTo(face.width / 2, 3));
  });

  test('alignAndCropFace không xoay khi gần như thẳng', () {
    final image = img.Image(width: 200, height: 200);
    final face = alignAndCropFace(
      image,
      left: 50,
      top: 50,
      width: 100,
      height: 100,
      rollDegrees: 0.5,
    );
    expect(face.width, 130); // 100 * kFaceCropScale (1.3)
  });

  test(
    'decodeUpright xoay ảnh theo EXIF (camera trước thường lưu ảnh nằm ngang)',
    () {
      // Ảnh 40x20, điểm đỏ ở góc trên-trái, EXIF orientation = 6 (cần xoay 90° theo chiều kim đồng hồ).
      final raw = img.Image(width: 40, height: 20)
        ..clear(img.ColorRgb8(255, 255, 255))
        ..setPixelRgb(0, 0, 255, 0, 0)
        ..setPixelRgb(1, 0, 255, 0, 0)
        ..setPixelRgb(0, 1, 255, 0, 0)
        ..setPixelRgb(1, 1, 255, 0, 0);
      raw.exif.imageIfd.orientation = 6;
      final jpeg = img.encodeJpg(raw, quality: 100);

      final decoded = decodeUpright(jpeg)!;

      expect(decoded.width, 20);
      expect(decoded.height, 40);
      expect(decoded.rgba.length, 20 * 40 * 4);
      // Sau khi xoay 90° theo chiều kim đồng hồ, góc trên-trái chuyển sang góc trên-phải.
      int red(int x, int y) => decoded.rgba[(y * decoded.width + x) * 4];
      int green(int x, int y) => decoded.rgba[(y * decoded.width + x) * 4 + 1];
      expect(red(19, 0), greaterThan(200));
      expect(green(19, 0), lessThan(80));
      expect(green(0, 0), greaterThan(200)); // góc trên-trái giờ là màu trắng
    },
  );

  test('Ảnh gửi ML Kit giữ đúng màu sau khi plugin đóng gói pixel', () {
    // Pixel RGBA: đỏ đậm (200, 30, 10).
    final rgba = Uint8List.fromList([200, 30, 10, 255]);
    final bytes = toMlKitBitmap(rgba);

    // google_mlkit_commons (Kotlin): int = a<<24 | b0<<16 | b1<<8 | b2.
    final packed =
        (bytes[3] << 24) | (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
    // Android ARGB_8888 + copyPixelsFromBuffer: int = A<<24 | B<<16 | G<<8 | R.
    final r = packed & 0xff,
        g = (packed >> 8) & 0xff,
        b = (packed >> 16) & 0xff;
    expect([r, g, b], [200, 30, 10]);

    // Nếu gửi thẳng RGBA thì đỏ/xanh bị đảo (lỗi trước đây).
    final wrong = (rgba[3] << 24) | (rgba[0] << 16) | (rgba[1] << 8) | rgba[2];
    expect([wrong & 0xff, (wrong >> 16) & 0xff], [10, 200]);
  });

  test('decodeUpright trả về cả RGBA và bản BGRA cho ML Kit', () {
    final raw = img.Image(width: 2, height: 1)..setPixelRgb(0, 0, 200, 30, 10);
    final decoded = decodeUpright(img.encodePng(raw))!;
    expect(decoded.rgba.sublist(0, 4), [200, 30, 10, 255]);
    expect(decoded.mlKitBitmap.sublist(0, 4), [10, 30, 200, 255]);
  });

  test('decodeUpright thu nhỏ ảnh lớn, giữ tỉ lệ', () {
    final jpeg = img.encodeJpg(img.Image(width: 2000, height: 1500));
    final decoded = decodeUpright(jpeg, maxSide: 1000)!;
    expect(decoded.width, 1000);
    expect(decoded.height, 750);
  });

  test('preprocessFace trả về tensor đúng kích thước model', () {
    final decoded = decodeUpright(
      img.encodeJpg(img.Image(width: 320, height: 240)),
    )!;
    final input = preprocessFace(
      decoded,
      left: 100,
      top: 60,
      width: 120,
      height: 120,
      size: 160,
      rollDegrees: 10,
    );
    expect(input.length, 160 * 160 * 3);
  });
}
