import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../../../core/link/lock_link.dart';
import 'ble_lock_data_source.dart';
import 'lan_lock_data_source.dart';

/// Máy chủ trung gian MQTT (vd. HiveMQ Cloud). Dùng chung cho app và khoá: app lưu trong kho bảo mật,
/// khoá nhận qua lệnh SET_MQTT. Chỉ hỗ trợ MQTT qua TLS.
class MqttSettings extends Equatable {
  const MqttSettings({required this.host, this.port = 8883, required this.user, required this.password});

  factory MqttSettings.fromJson(Map<String, dynamic> m) => MqttSettings(
        host: m['host'] as String,
        port: m['port'] as int,
        user: m['user'] as String,
        password: m['password'] as String,
      );

  final String host;
  final int port;
  final String user;
  final String password;

  Map<String, dynamic> toJson() => {'host': host, 'port': port, 'user': user, 'password': password};

  @override
  List<Object?> get props => [host, port, user, password];
}

/// Chủ đề MQTT của 1 khoá (khớp firmware: MQTT_TOPIC_PREFIX/<địa chỉ BLE 12 hex thường>/c|e|s).
({String cmd, String evt, String status})? lockTopics(String lockId) {
  final mac = macBytes(lockId);
  if (mac == null) return null;
  final id = mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return (cmd: 'khoabaomat/$id/c', evt: 'khoabaomat/$id/e', status: 'khoabaomat/$id/s');
}

/// Lớp dữ liệu điều khiển từ xa: gửi/nhận đúng các gói như BLE qua máy chủ MQTT.
/// Không biết gì về mã hoá – máy chủ chỉ thấy gói đã mã hoá AES-GCM.
class MqttLockDataSource implements LockTransport {
  MqttLockDataSource([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'mqtt.settings';

  final FlutterSecureStorage _storage;
  final _frames = StreamController<Uint8List>.broadcast();
  MqttServerClient? _client;
  ({String cmd, String evt, String status})? _topics;
  String? _lockId;
  final _clientId = 'kbm-app-${Random.secure().nextInt(1 << 32).toRadixString(16)}';

  @override
  Stream<Uint8List> get frames => _frames.stream;

  Future<MqttSettings?> settings() async {
    final raw = await _storage.read(key: _key);
    return raw == null ? null : MqttSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// null = xoá (tắt điều khiển từ xa trên máy này).
  Future<void> saveSettings(MqttSettings? s) =>
      s == null ? _storage.delete(key: _key) : _storage.write(key: _key, value: jsonEncode(s.toJson()));

  /// Vào máy chủ và kiểm tra khoá đang online. false = chưa cài máy chủ, không vào được máy chủ,
  /// hoặc khoá đang offline (máy chủ giữ cờ "0" khoá để lại khi mất mạng).
  Future<bool> connect(String lockId) async {
    disconnect();
    final s = await settings();
    final topics = lockTopics(lockId);
    if (s == null || topics == null) return false;
    final c = MqttServerClient.withPort(s.host, _clientId, s.port)
      ..secure = true
      ..keepAlivePeriod = 30
      ..connectTimeoutPeriod = 6000
      ..autoReconnect = true
      ..logging(on: false)
      ..setProtocolV311();
    c.connectionMessage = MqttConnectMessage().withClientIdentifier(_clientId).startClean();
    try {
      await c.connect(s.user, s.password);
    } on Exception {
      c.disconnect();
      return false;
    }
    if (c.connectionStatus?.state != MqttConnectionState.connected) return false;

    final online = Completer<bool>();
    c.updates?.listen((msgs) {
      for (final m in msgs) {
        final bytes = Uint8List.fromList((m.payload as MqttPublishMessage).payload.message);
        if (m.topic == topics.evt && bytes.isNotEmpty) _frames.add(bytes);
        if (m.topic == topics.status && !online.isCompleted) online.complete(bytes.length == 1 && bytes[0] == 0x31);
      }
    });
    c
      ..subscribe(topics.evt, MqttQos.atMostOnce)
      ..subscribe(topics.status, MqttQos.atMostOnce);
    // Cờ trạng thái được máy chủ giữ lại nên tới ngay; không có = khoá chưa từng vào máy chủ này
    final isOnline = await online.future.timeout(const Duration(seconds: 3), onTimeout: () => false);
    if (!isOnline) {
      c.disconnect();
      return false;
    }
    _client = c;
    _topics = topics;
    _lockId = lockId;
    return true;
  }

  void disconnect() {
    _client?.disconnect();
    _client = null;
  }

  @override
  Future<Uint8List> request(
    List<int> frame, {
    required Set<int> replyKinds,
    Duration timeout = const Duration(seconds: 8), // qua internet chậm hơn BLE / Wi-Fi trong nhà
  }) async {
    final id = _lockId;
    if (_client?.connectionStatus?.state != MqttConnectionState.connected &&
        (id == null || !await connect(id))) {
      throw const BleException('Không vào được máy chủ trung gian hoặc khoá đang offline');
    }
    final reply = frames
        .firstWhere((f) => f.isNotEmpty && replyKinds.contains(f[0]))
        .timeout(timeout < const Duration(seconds: 8) ? const Duration(seconds: 8) : timeout);
    final b = MqttClientPayloadBuilder();
    for (final x in frame) {
      b.addByte(x);
    }
    _client!.publishMessage(_topics!.cmd, MqttQos.atMostOnce, b.payload!);
    return reply;
  }
}
