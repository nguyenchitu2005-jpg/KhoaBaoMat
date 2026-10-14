import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/face_math.dart';

/// Lưu vector khuôn mặt đã đăng ký (FaceNet-512) trong kho bảo mật của máy.
/// Chỉ lưu vector, không lưu ảnh. Một khuôn mặt cho cả app (chủ điện thoại).
class FaceStore {
  FaceStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'face_embedding_v1';

  final FlutterSecureStorage _storage;

  /// null = chưa đăng ký, hoặc vector của model cũ (khác số chiều) -> phải đăng ký lại.
  Future<List<double>?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      final v = [for (final x in jsonDecode(raw) as List) (x as num).toDouble()];
      return isCurrentFaceEmbedding(v) ? v : null;
    } on Object {
      return null; // dữ liệu hỏng: coi như chưa đăng ký
    }
  }

  Future<void> save(List<double> embedding) => _storage.write(key: _key, value: jsonEncode(embedding));

  Future<void> clear() => _storage.delete(key: _key);
}
