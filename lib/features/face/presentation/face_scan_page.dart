import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../domain/liveness_checker.dart';
import '../data/face_recognition_service.dart';

/// Màn hình quét khuôn mặt bằng camera trước.
///
/// 1. Phân tích luồng camera bằng ML Kit để kiểm tra người thật (nháy mắt).
/// 2. Chụp [shots] ảnh đạt chất lượng, tạo vector khuôn mặt bằng FaceNet-512.
/// 3. Đóng màn hình và trả về danh sách vector (`List<List<double>>`), hoặc null nếu huỷ.
class FaceScanScreen extends StatefulWidget {
  const FaceScanScreen({super.key, required this.title, this.shots = 1});

  final String title;
  final int shots;

  @override
  State<FaceScanScreen> createState() => _FaceScanScreenState();
}

enum _Phase { starting, liveness, capturing, error }

class _FaceScanScreenState extends State<FaceScanScreen>
    with WidgetsBindingObserver {
  static const _deviceRotation = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  // Dùng chung một bản cho cả app (model chỉ nạp một lần) – không đóng khi rời màn hình.
  final _recognizer = FaceRecognitionService.instance;

  /// Quá thời gian này mà camera chưa chụp xong / chưa xử lý xong 1 ảnh thì báo lỗi
  /// thay vì đứng mãi.
  static const _shotTimeout = Duration(seconds: 15);
  final _streamDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true, // cần xác suất mắt mở để phát hiện nháy mắt
      minFaceSize: 0.25,
    ),
  );
  final _liveness = LivenessChecker();

  CameraController? _controller;
  _Phase _phase = _Phase.starting;
  String _status = 'Đang mở camera…';
  int _stage = 0; // 0: nhìn vào camera, 1: nháy mắt, 2: chụp ảnh
  bool _processingFrame = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _streamDetector.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Giải phóng camera khi app ra nền, mở lại khi quay về.
    if (state == AppLifecycleState.inactive) {
      final controller = _controller;
      _controller = null;
      controller?.dispose();
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _start();
    }
  }

  Future<void> _start() async {
    // Hộp thoại xin quyền camera làm app "inactive" rồi "resumed": tránh mở camera 2 lần.
    if (_starting) return;
    _starting = true;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _fail('Thiết bị không có camera.');
        return;
      }
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup:
            ImageFormatGroup.nv21, // định dạng ML Kit đọc được trên Android
      );
      await controller.initialize();
      await _recognizer.load();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _liveness.reset();
      setState(() {
        _phase = _Phase.liveness;
        _stage = 0;
        _status = LivenessChecker.message(LivenessStep.noFace);
      });
      await controller.startImageStream(_onFrame);
    } on CameraException catch (e) {
      _fail(
        e.code.contains('Access') || e.code.contains('Permission')
            ? 'Chưa cấp quyền camera. Hãy cho phép trong Cài đặt > Ứng dụng.'
            : 'Không mở được camera: ${e.description ?? e.code}',
      );
    } catch (e) {
      _fail('Không tải được model nhận diện: $e');
    } finally {
      _starting = false;
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_processingFrame || _phase != _Phase.liveness) return;
    final input = _toInputImage(image);
    if (input == null) return;
    _processingFrame = true;
    try {
      final faces = await _streamDetector.processImage(input);
      if (!mounted || _phase != _Phase.liveness) return;
      final face = faces.length == 1 ? faces.first : null;
      final step = _liveness.update(
        faceCount: faces.length,
        leftEye: face?.leftEyeOpenProbability,
        rightEye: face?.rightEyeOpenProbability,
        headY: face?.headEulerAngleY,
      );
      setState(() {
        _status = LivenessChecker.message(step);
        _stage = switch (step) {
          LivenessStep.blink || LivenessStep.reopenEyes => 1,
          LivenessStep.passed => 2,
          _ => 0,
        };
      });
      if (step == LivenessStep.passed) await _capture();
    } catch (_) {
      // Bỏ qua khung hình lỗi, xử lý khung tiếp theo.
    } finally {
      _processingFrame = false;
    }
  }

  InputImage? _toInputImage(CameraImage image) {
    final controller = _controller;
    if (controller == null || image.planes.length != 1) return null;
    final camera = controller.description;
    final device = _deviceRotation[controller.value.deviceOrientation] ?? 0;
    final degrees = camera.lensDirection == CameraLensDirection.front
        ? (camera.sensorOrientation + device) % 360
        : (camera.sensorOrientation - device + 360) % 360;
    final rotation = InputImageRotationValue.fromRawValue(degrees);
    if (rotation == null) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _phase = _Phase.capturing;
      _stage = 2;
    });

    final embeddings = <List<double>>[];
    String? lastProblem;
    try {
      await controller.stopImageStream();
      var attempts = 0;
      while (embeddings.length < widget.shots && attempts < widget.shots * 3) {
        attempts++;
        if (!mounted) return;
        setState(
          () => _status =
              lastProblem ??
              'Giữ yên… đang chụp ${embeddings.length + 1}/${widget.shots}',
        );
        final file = await controller.takePicture().timeout(_shotTimeout);
        try {
          final result = await _recognizer
              .embeddingFromFile(file.path)
              .timeout(_shotTimeout);
          if (result.embedding != null) {
            embeddings.add(result.embedding!);
            lastProblem = null;
          } else {
            lastProblem = result.problem;
          }
        } finally {
          File(file.path).delete().ignore();
        }
        // Nghỉ ngắn giữa các ảnh để có chút khác biệt (ánh sáng, biểu cảm),
        // giúp mẫu đăng ký bao quát hơn thay vì nhiều ảnh giống hệt nhau.
        if (embeddings.length < widget.shots) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
      }
    } on TimeoutException {
      _fail('Camera không phản hồi. Hãy thử lại.');
      return;
    } catch (e) {
      _fail('Lỗi khi chụp ảnh: $e');
      return;
    }
    if (!mounted) return;

    if (embeddings.length < widget.shots) {
      // Ảnh chưa đạt: quay lại bước kiểm tra người thật và báo lý do.
      _liveness.reset();
      setState(() {
        _phase = _Phase.liveness;
        _stage = 0;
        _status = '${lastProblem ?? 'Không thấy rõ khuôn mặt'} – hãy thử lại';
      });
      try {
        await controller.startImageStream(_onFrame);
      } on CameraException catch (e) {
        _fail('Không mở lại được camera: ${e.description ?? e.code}');
      }
      return;
    }
    Navigator.of(context).pop(embeddings);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _status = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ready = controller != null && controller.value.isInitialized;
    final guideColor = switch (_phase) {
      _Phase.capturing => const Color(0xFF22C55E),
      _Phase.error => scheme.error,
      _ when _stage == 1 => const Color(0xFFFBBF24),
      _ => Colors.white,
    };
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(widget.title),
        foregroundColor: Colors.white,
        titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
          color: Colors.white,
        ),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      body: Stack(
        children: [
          if (ready) ...[
            Positioned.fill(child: _CoverPreview(controller)),
            Positioned.fill(
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: guideColor),
                duration: const Duration(milliseconds: 250),
                builder: (_, color, _) => CustomPaint(
                  painter: _FaceGuidePainter(color ?? guideColor),
                ),
              ),
            ),
          ] else
            Positioned.fill(
              bottom: 220,
              child: Center(
                child: _phase == _Phase.error
                    ? Icon(
                        Icons.no_photography_outlined,
                        size: 96,
                        color: scheme.error,
                      )
                    : const CircularProgressIndicator(color: Colors.white),
              ),
            ),
          Align(alignment: Alignment.bottomCenter, child: _buildPanel(theme)),
        ],
      ),
    );
  }

  Widget _buildPanel(ThemeData theme) {
    final scheme = theme.colorScheme;
    final (IconData icon, Color color) = switch (_phase) {
      _Phase.starting => (Icons.hourglass_top_rounded, scheme.onSurfaceVariant),
      _Phase.error => (Icons.error_outline_rounded, scheme.error),
      _Phase.capturing => (Icons.photo_camera_rounded, const Color(0xFF16A34A)),
      _Phase.liveness when _stage == 1 => (
        Icons.remove_red_eye_rounded,
        scheme.primary,
      ),
      _Phase.liveness => (Icons.face_rounded, scheme.primary),
    };
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepIndicator(stage: _stage, error: _phase == _Phase.error),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 10),
              Flexible(
                child: FadingStatusText(
                  _status,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (_phase == _Phase.capturing) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: const LinearProgressIndicator(minHeight: 6),
            ),
          ] else if (_phase == _Phase.error) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Quay lại'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Hiển thị camera phủ kín vùng chứa mà không bị méo hình.
class _CoverPreview extends StatelessWidget {
  const _CoverPreview(this.controller);

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.previewSize;
    if (size == null) return CameraPreview(controller);
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        // previewSize là kích thước ngang của cảm biến; màn hình dọc nên đảo chiều.
        child: SizedBox(
          width: size.height,
          height: size.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

/// 3 bước: nhìn vào camera → nháy mắt → chụp ảnh.
class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.stage, required this.error});

  static const _labels = ['Nhìn camera', 'Nháy mắt', 'Chụp ảnh'];

  final int stage;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        for (var i = 0; i < _labels.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 3,
                margin: const EdgeInsets.only(bottom: 22),
                decoration: BoxDecoration(
                  color: i <= stage && !error
                      ? scheme.primary
                      : scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          _StepDot(
            index: i,
            label: _labels[i],
            done: i < stage && !error,
            active: i == stage && !error,
          ),
        ],
      ],
    );
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.index,
    required this.label,
    required this.done,
    required this.active,
  });

  final int index;
  final String label;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final highlighted = done || active;
    return SizedBox(
      width: 76,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done
                  ? scheme.primary
                  : active
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              border: active
                  ? Border.all(color: scheme.primary, width: 2)
                  : null,
            ),
            alignment: Alignment.center,
            child: done
                ? Icon(Icons.check_rounded, size: 18, color: scheme.onPrimary)
                : Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: active
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: highlighted ? FontWeight.w700 : FontWeight.w500,
              color: highlighted ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Làm tối vùng ngoài khung oval và vẽ viền oval hướng dẫn đặt khuôn mặt.
class _FaceGuidePainter extends CustomPainter {
  _FaceGuidePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final ovalWidth = size.width * 0.72;
    final oval = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.38),
      width: ovalWidth,
      height: ovalWidth * 1.3,
    );
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addOval(oval),
    );
    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawOval(
      oval,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
  }

  @override
  bool shouldRepaint(_FaceGuidePainter oldDelegate) =>
      oldDelegate.color != color;
}

class FadingStatusText extends StatefulWidget {
  const FadingStatusText(this.text, {super.key, this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  State<FadingStatusText> createState() => _FadingStatusTextState();
}

class _FadingStatusTextState extends State<FadingStatusText> {
  int _version = 0;

  @override
  void didUpdateWidget(FadingStatusText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _version++;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Text(
        widget.text,
        key: ValueKey(_version),
        textAlign: widget.textAlign,
        style: widget.style,
      ),
    );
  }
}

/// Biểu tượng nằm trong ô vuông bo góc tô màu nhạt.
