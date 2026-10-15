import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../domain/face_math.dart';

/// Kết quả xử lý 1 ảnh: [embedding] nếu thành công, nếu không thì [problem] là lý do (tiếng Việt).
typedef FaceEmbeddingResult = ({List<double>? embedding, String? problem});

/// Nhận diện khuôn mặt trên ảnh đã chụp:
/// ML Kit tìm khuôn mặt + vị trí 2 mắt -> kiểm tra chất lượng -> căn thẳng & cắt ảnh
/// -> FaceNet-512 (TFLite) tạo vector 512 chiều.
///
/// Dùng chung MỘT bản cho cả app ([instance]), nạp model một lần và giữ suốt phiên chạy:
/// `Interpreter.fromAsset` của tflite_flutter chép model (24 MB) vào bộ nhớ native và không
/// bao giờ giải phóng bản chép đó, kể cả khi đóng interpreter. Bản cũ nạp lại model mỗi lần
/// mở màn quét nên mỗi lần quét mất thêm ~24 MB; quét nhiều lần (đổi tài khoản, đăng ký lại…)
/// làm app chiếm hàng trăm MB, máy chạy ì và trông như bị đứng ở ảnh thứ 2.
class FaceRecognitionService {
  FaceRecognitionService._();

  static final instance = FaceRecognitionService._();

  static const modelAsset = kFaceModelAsset;

  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableLandmarks: true, // vị trí 2 mắt để căn thẳng khuôn mặt
      enableClassification: true, // xác suất mắt mở để loại ảnh nhắm mắt
    ),
  );
  Interpreter? _interpreter;
  Future<void>? _loading;
  late int _inputSize;
  late int _outputLength;

  /// Nạp model (chỉ lần đầu; các lần sau trả về ngay).
  Future<void> load() =>
      _loading ??= _load().catchError((Object e, StackTrace stack) {
        _loading = null; // lỗi thì lần sau thử nạp lại
        Error.throwWithStackTrace(e, stack);
      });

  Future<void> _load() async {
    // 4 luồng CPU: FaceNet nặng hơn MobileFaceNet nhiều, chạy 1 luồng làm khựng giao diện.
    final options = InterpreterOptions()..threads = 4;
    final interpreter = await Interpreter.fromAsset(
      modelAsset,
      options: options,
    );
    // Model có đầu vào [1, 160, 160, 3] và đầu ra [1, 512]; đọc từ model để không hard-code.
    final inputShape = interpreter.getInputTensor(0).shape;
    if (inputShape.first != 1) {
      interpreter.resizeInputTensor(0, [1, ...inputShape.skip(1)]);
    }
    interpreter.allocateTensors();
    _inputSize = interpreter.getInputTensor(0).shape[1];
    _outputLength = interpreter.getOutputTensor(0).shape.last;
    _interpreter = interpreter;
  }

  /// Tạo vector cho khuôn mặt lớn nhất trong ảnh, hoặc trả về lý do ảnh không dùng được.
  Future<FaceEmbeddingResult> embeddingFromFile(String path) async {
    await load();
    final interpreter = _interpreter!;

    // Giải mã + xoay đúng chiều một lần; ML Kit và bước cắt ảnh dùng chung mảng pixel này
    // nên toạ độ khuôn mặt luôn khớp (xem decodeUpright).
    final bytes = await File(path).readAsBytes();
    final image = await Isolate.run(() => decodeUpright(bytes));
    if (image == null) return (embedding: null, problem: 'Không đọc được ảnh');

    final faces = await _detector.processImage(
      InputImage.fromBitmap(
        bitmap: image.mlKitBitmap, // BGRA – xem toMlKitBitmap
        width: image.width,
        height: image.height,
      ),
    );
    if (faces.isEmpty) {
      return (embedding: null, problem: 'Không thấy rõ khuôn mặt');
    }
    final face = faces.reduce(
      (a, b) =>
          a.boundingBox.width * a.boundingBox.height >=
              b.boundingBox.width * b.boundingBox.height
          ? a
          : b,
    );

    final problem = faceQualityProblem(
      headY: face.headEulerAngleY,
      headX: face.headEulerAngleX,
      leftEyeOpen: face.leftEyeOpenProbability,
      rightEyeOpen: face.rightEyeOpenProbability,
      faceWidth: face.boundingBox.width,
      imageWidth: image.width.toDouble(),
    );
    if (problem != null) return (embedding: null, problem: problem);

    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
    final roll = leftEye != null && rightEye != null
        ? eyeLineAngle(
            leftEye.x.toDouble(),
            leftEye.y.toDouble(),
            rightEye.x.toDouble(),
            rightEye.y.toDouble(),
          )
        : 0.0;

    final box = face.boundingBox;
    final size = _inputSize;
    final input = await Isolate.run(
      () => preprocessFace(
        image,
        left: box.left,
        top: box.top,
        width: box.width,
        height: box.height,
        size: size,
        rollDegrees: roll,
      ),
    );

    if (kDebugMode) _saveDebugCrop(input, size);

    final output = Float32List(_outputLength);
    interpreter.run(input.buffer, output.buffer);
    return (embedding: l2Normalize(output), problem: null);
  }

  int _debugCrops = 0;

  /// Chỉ ở bản debug: lưu ảnh khuôn mặt đưa vào model (đã căn thẳng, cắt, 160×160; độ sáng
  /// kéo giãn lại để xem được), để kiểm tra bước cắt có lấy đúng khuôn mặt không. Giữ 4 ảnh
  /// gần nhất trong thư mục tạm của app; lấy về máy tính bằng:
  ///   adb exec-out run-as com.khoabaomat.khoabaomat cat code_cache/face_debug_0.png > face0.png
  /// Chạy nền (Isolate), không làm chậm việc nhận diện.
  void _saveDebugCrop(Float32List input, int size) {
    final path =
        '${Directory.systemTemp.path}/face_debug_${_debugCrops++ % 4}.png';
    unawaited(
      Isolate.run(() => _writeDebugPng(input, size, path)).then(
        (_) => debugPrint('Ảnh khuôn mặt đưa vào model: $path'),
        onError: (Object e) => debugPrint('Không lưu được ảnh debug: $e'),
      ),
    );
  }
}

void _writeDebugPng(Float32List input, int size, String path) {
  final image = img.Image(width: size, height: size);
  final lo = input.reduce(min);
  final range = max(input.reduce(max) - lo, 1e-6);
  int channel(int i) => ((input[i] - lo) / range * 255).round().clamp(0, 255);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 3;
      image.setPixelRgb(x, y, channel(i), channel(i + 1), channel(i + 2));
    }
  }
  File(path).writeAsBytesSync(img.encodePng(image));
}
