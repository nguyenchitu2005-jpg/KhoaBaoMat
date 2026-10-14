import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Model nhận diện khuôn mặt: FaceNet-512 (Inception-ResNet-v1 huấn luyện trên VGGFace2),
/// đầu vào 160×160×3 chuẩn hoá theo từng ảnh, đầu ra vector 512 chiều.
/// Thay cho MobileFaceNet (192 chiều): đo trên LFW, ở cùng mức "người giống nhất lọt 0,3%"
/// FaceNet-512 nhận đúng chính chủ ~90% so với ~70% (xem README mục 7.3).
const kFaceModelAsset = 'assets/models/facenet_512.tflite';

/// Số chiều vector của model hiện tại. Vector có số chiều khác là của model cũ – không so
/// sánh được, phải đăng ký lại khuôn mặt.
const kFaceEmbeddingLength = 512;

bool isCurrentFaceEmbedding(List<double> embedding) =>
    embedding.length == kFaceEmbeddingLength;

/// Vùng cắt = cạnh dài của khung khuôn mặt (ML Kit) × hệ số này: FaceNet được huấn luyện
/// với ảnh có chừa lề quanh mặt (đo trên LFW: lề 20–50% cho kết quả gần như nhau).
const kFaceCropScale = 1.3;

/// Mức an toàn khi so khớp khuôn mặt = ngưỡng khoảng cách Euclid giữa 2 vector
/// (đã chuẩn hoá L2, giá trị 0..2). Khoảng cách nhỏ hơn ngưỡng => cùng một người.
/// Ngưỡng càng nhỏ càng chặt: ít nhận nhầm người khác, nhưng dễ từ chối chính chủ hơn
/// (khi đó cứ thử lại, hoặc đăng ký lại khuôn mặt ở nơi đủ sáng).
///
/// Đo FaceNet-512 trên bộ ảnh LFW (217 người; mẫu = trung bình 5 ảnh; đăng nhập lấy ảnh
/// tốt nhất trong 2; "người giống nhất" = 10 người có mẫu gần nhất với mỗi người):
///   ngưỡng | chính chủ được nhận | người lạ ngẫu nhiên lọt | người giống nhất lọt
///    0.75  |        ~96%         |          0.03%          |       ~1%     Cơ bản
///    0.65  |        ~83%         |          0%             |       ~0.1%   Cao
///    0.55  |        ~53%         |          0%             |       ~0.01%  Rất cao
/// (MobileFaceNet cũ ở ngưỡng 0.95: người giống nhất lọt 21%.)
/// Ảnh LFW chụp ở nhiều thời điểm/ánh sáng khác nhau nên chính chủ khó hơn thực tế; trên
/// điện thoại (cùng camera, vừa đăng ký) khoảng cách của chính chủ thường nhỏ hơn nhiều.
/// Xem README mục 7.3.
enum FaceSecurityLevel {
  standard(0.75, 'Cơ bản'),
  high(0.65, 'Cao'),
  veryHigh(0.55, 'Rất cao');

  const FaceSecurityLevel(this.threshold, this.label);

  final double threshold;
  final String label;

  static FaceSecurityLevel fromName(String? name) => values.firstWhere(
    (l) => l.name == name,
    orElse: () => kDefaultFaceSecurityLevel,
  );
}

const kDefaultFaceSecurityLevel = FaceSecurityLevel.high;

/// Chuẩn hoá vector về độ dài 1 để so sánh khoảng cách ổn định.
List<double> l2Normalize(List<double> v) {
  var sum = 0.0;
  for (final x in v) {
    sum += x * x;
  }
  final norm = sqrt(sum);
  if (norm == 0) return List<double>.from(v);
  return [for (final x in v) x / norm];
}

double euclideanDistance(List<double> a, List<double> b) {
  if (a.length != b.length) {
    throw ArgumentError('Hai vector khác số chiều: ${a.length} và ${b.length}');
  }
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    sum += d * d;
  }
  return sqrt(sum);
}

/// Trung bình nhiều vector (dùng khi đăng ký bằng nhiều ảnh) rồi chuẩn hoá lại.
List<double> averageEmbeddings(List<List<double>> embeddings) {
  if (embeddings.isEmpty) throw ArgumentError('Danh sách vector rỗng');
  final sum = List<double>.filled(embeddings.first.length, 0);
  for (final e in embeddings) {
    for (var i = 0; i < sum.length; i++) {
      sum[i] += e[i];
    }
  }
  return l2Normalize([for (final x in sum) x / embeddings.length]);
}

/// Khoảng cách từ vector đã đăng ký tới từng ảnh vừa chụp.
List<double> distancesTo(List<double> reference, List<List<double>> samples) {
  if (samples.isEmpty) throw ArgumentError('Danh sách ảnh rỗng');
  return [for (final s in samples) euclideanDistance(reference, s)];
}

/// Khoảng cách dùng để quyết định khi đăng nhập: ảnh KHỚP NHẤT trong các ảnh vừa chụp
/// (1 ảnh mờ/lệch không làm hỏng lần đăng nhập). Đo trên LFW, cách này tốt hơn bắt mọi
/// ảnh đều khớp (MobileFaceNet: ở cùng mức người giống nhất lọt ~1.3%, chính chủ được
/// nhận 81% so với 61%).
/// Muốn ít nhận nhầm hơn thì hạ ngưỡng (FaceSecurityLevel), không đổi cách này.
double matchDistance(List<double> reference, List<List<double>> samples) =>
    distancesTo(reference, samples).reduce(min);

/// Góc nghiêng (độ) của đường nối 2 mắt so với phương ngang.
/// Dương nghĩa là mắt nằm bên phải ảnh thấp hơn. Không phụ thuộc thứ tự 2 điểm.
double eyeLineAngle(double x1, double y1, double x2, double y2) {
  if (x2 < x1) return eyeLineAngle(x2, y2, x1, y1);
  return atan2(y2 - y1, x2 - x1) * 180 / pi;
}

/// Ngưỡng chất lượng cho ảnh dùng để nhận diện.
const double kMaxHeadTurn = 15; // độ, quay trái/phải (Y) và ngẩng/cúi (X)
const double kMinEyeOpen = 0.4;
const double kMinFaceRatio = 0.25; // bề rộng khuôn mặt / bề rộng ảnh

/// Trả về lý do ảnh khuôn mặt chưa đạt (tiếng Việt), hoặc null nếu đạt.
/// Giá trị null (ML Kit không trả về) được bỏ qua.
String? faceQualityProblem({
  double? headY,
  double? headX,
  double? leftEyeOpen,
  double? rightEyeOpen,
  double? faceWidth,
  double? imageWidth,
}) {
  // Mặt quá nhỏ (đứng xa) => vùng mặt chỉ vài chục pixel, phóng lên 160x160 bị nhoè.
  if (faceWidth != null &&
      imageWidth != null &&
      imageWidth > 0 &&
      faceWidth / imageWidth < kMinFaceRatio) {
    return 'Hãy đưa mặt lại gần camera hơn';
  }
  if (headY != null && headY.abs() > kMaxHeadTurn) {
    return 'Hãy nhìn thẳng, đừng quay đầu sang bên';
  }
  if (headX != null && headX.abs() > kMaxHeadTurn) {
    return 'Hãy giữ đầu thẳng, đừng ngẩng hoặc cúi';
  }
  if ((leftEyeOpen != null && leftEyeOpen < kMinEyeOpen) ||
      (rightEyeOpen != null && rightEyeOpen < kMinEyeOpen)) {
    return 'Hãy mở mắt khi chụp';
  }
  return null;
}

/// Cắt hình vuông cạnh [side] có tâm (cx, cy), dồn vào trong nếu chạm mép ảnh.
img.Image _squareCrop(img.Image image, double cx, double cy, double side) {
  final s = min(side, min(image.width, image.height).toDouble());
  final x = (cx - s / 2).clamp(0, image.width - s).round();
  final y = (cy - s / 2).clamp(0, image.height - s).round();
  return img.copyCrop(image, x: x, y: y, width: s.round(), height: s.round());
}

/// Cắt vùng vuông quanh khuôn mặt (cạnh = cạnh dài của khung × [scale]),
/// giới hạn trong khung ảnh.
img.Image cropFace(
  img.Image image, {
  required double left,
  required double top,
  required double width,
  required double height,
  double scale = kFaceCropScale,
}) => _squareCrop(
  image,
  left + width / 2,
  top + height / 2,
  max(width, height) * scale,
);

/// Xoay ảnh để đường nối 2 mắt nằm ngang rồi cắt khuôn mặt.
/// Mặt nghiêng vài độ cũng làm vector thay đổi nhiều, nên căn thẳng giúp kết quả ổn định.
img.Image alignAndCropFace(
  img.Image image, {
  required double left,
  required double top,
  required double width,
  required double height,
  double rollDegrees = 0,
  double scale = kFaceCropScale,
}) {
  if (rollDegrees.abs() < 1) {
    return cropFace(
      image,
      left: left,
      top: top,
      width: width,
      height: height,
      scale: scale,
    );
  }
  final side = max(width, height) * scale;
  final cx = left + width / 2;
  final cy = top + height / 2;

  // Cắt trước một vùng rộng hơn (1.5 lần) để xoay không bị hụt góc, và để xoay nhanh hơn.
  final half = side * 0.75;
  final x0 = max(0, (cx - half).floor());
  final y0 = max(0, (cy - half).floor());
  final x1 = min(image.width, (cx + half).ceil());
  final y1 = min(image.height, (cy + half).ceil());
  final region = img.copyCrop(
    image,
    x: x0,
    y: y0,
    width: x1 - x0,
    height: y1 - y0,
  );

  final rotated = img.copyRotate(
    region,
    angle: -rollDegrees,
    interpolation: img.Interpolation.linear,
  );

  // Vị trí tâm khuôn mặt sau khi xoay (copyRotate xoay quanh tâm ảnh và nới rộng khung).
  final fx = cx - x0 - region.width / 2;
  final fy = cy - y0 - region.height / 2;
  final rad = -rollDegrees * pi / 180;
  final newCx = rotated.width / 2 + fx * cos(rad) - fy * sin(rad);
  final newCy = rotated.height / 2 + fx * sin(rad) + fy * cos(rad);
  return _squareCrop(rotated, newCx, newCy, side);
}

/// Đổi ảnh RGB thành mảng float [H, W, 3] theo đúng cách FaceNet được huấn luyện
/// ("prewhiten"): trừ trung bình rồi chia độ lệch chuẩn của chính ảnh đó (tính trên mọi
/// kênh), nên kết quả ít phụ thuộc độ sáng/độ tương phản của ảnh.
Float32List imageToModelInput(img.Image image) {
  final out = Float32List(image.width * image.height * 3);
  var i = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      out[i++] = p.r.toDouble();
      out[i++] = p.g.toDouble();
      out[i++] = p.b.toDouble();
    }
  }
  var mean = 0.0;
  for (final v in out) {
    mean += v;
  }
  mean /= out.length;
  var variance = 0.0;
  for (final v in out) {
    variance += (v - mean) * (v - mean);
  }
  final std = max(sqrt(variance / out.length), 1 / sqrt(out.length));
  for (var k = 0; k < out.length; k++) {
    out[k] = (out[k] - mean) / std;
  }
  return out;
}

/// Ảnh đã giải mã, xoay đúng chiều theo EXIF.
/// - [rgba]: pixel thứ tự R,G,B,A – dùng để cắt khuôn mặt và tạo vector.
/// - [mlKitBitmap]: cùng ảnh nhưng thứ tự B,G,R,A – dùng cho `InputImage.fromBitmap` (xem [toMlKitBitmap]).
typedef DecodedImage = ({
  Uint8List rgba,
  Uint8List mlKitBitmap,
  int width,
  int height,
});

/// Đổi mảng RGBA sang thứ tự mà `InputImage.fromBitmap` của google_mlkit_commons cần.
///
/// Phần Android của plugin đóng gói mỗi pixel thành `A<<24 | b0<<16 | b1<<8 | b2` (b0..b2 là 3 byte
/// đầu) rồi `Bitmap.copyPixelsFromBuffer`. Với `ARGB_8888`, Android đọc số nguyên đó theo công thức
/// `A<<24 | B<<16 | G<<8 | R`, nên byte đầu tiên bị hiểu là kênh **xanh dương**. Nếu gửi RGBA thì ML Kit
/// thấy ảnh bị đảo đỏ/xanh (mặt màu xanh lam) – phát hiện mặt, vị trí mắt, mắt mở/nhắm kém ổn định.
/// Gửi BGRA thì sau khi plugin đóng gói, màu trở về đúng.
Uint8List toMlKitBitmap(Uint8List rgba) {
  final out = Uint8List(rgba.length);
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    out[i] = rgba[i + 2];
    out[i + 1] = rgba[i + 1];
    out[i + 2] = rgba[i];
    out[i + 3] = rgba[i + 3];
  }
  return out;
}

/// Giải mã ảnh JPEG đã chụp, xoay/lật đúng chiều theo EXIF và thu nhỏ nếu cạnh dài hơn [maxSide].
///
/// Cùng một mảng pixel này được đưa cho ML Kit (tìm khuôn mặt) và cho bước cắt ảnh, nên toạ độ
/// khuôn mặt luôn khớp với ảnh được cắt – không phụ thuộc việc ML Kit và gói `image` xử lý EXIF
/// (ảnh camera trước thường bị xoay 90°/270° và có thể bị lật) giống hay khác nhau.
/// Hàm thuần Dart, chạy được trong Isolate.
DecodedImage? decodeUpright(Uint8List encoded, {int maxSide = 1024}) {
  final decoded = img.decodeImage(encoded);
  if (decoded == null) return null;
  var upright = img.bakeOrientation(decoded);
  final longest = max(upright.width, upright.height);
  if (longest > maxSide) {
    upright = upright.width >= upright.height
        ? img.copyResize(
            upright,
            width: maxSide,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            upright,
            height: maxSide,
            interpolation: img.Interpolation.average,
          );
  }
  final rgba = upright.getBytes(order: img.ChannelOrder.rgba, alpha: 255);
  return (
    rgba: rgba,
    mlKitBitmap: toMlKitBitmap(rgba),
    width: upright.width,
    height: upright.height,
  );
}

/// Căn thẳng 2 mắt ([rollDegrees]), cắt khuôn mặt từ ảnh [image] và resize về [size]x[size],
/// trả về tensor đầu vào cho model. Hàm thuần Dart, chạy được trong Isolate.
Float32List preprocessFace(
  DecodedImage image, {
  required double left,
  required double top,
  required double width,
  required double height,
  required int size,
  double rollDegrees = 0,
}) {
  final source = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: image.rgba.buffer,
    bytesOffset: image.rgba.offsetInBytes,
    numChannels: 4,
  );
  final face = alignAndCropFace(
    source,
    left: left,
    top: top,
    width: width,
    height: height,
    rollDegrees: rollDegrees,
  );
  final resized = img.copyResize(
    face,
    width: size,
    height: size,
    interpolation: img.Interpolation.linear,
  );
  return imageToModelInput(resized);
}
