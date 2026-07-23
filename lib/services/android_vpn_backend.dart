import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vpn_backend.dart';
import 'vpn_traffic_stats.dart';

/// Android VPN backend — VLESS + Reality через flutter_v2ray.
///
/// Конфиг:
///   - flow убран (несовместим с Mux, мешает tun2socks)
///   - DNS outbound для маршрутизации DNS-запросов через V2Ray
///   - SOCKS5 inbound на порту 1080 (flutter_v2ray по умолчанию)
///   - tun2socks пробрасывает весь трафик из TUN → SOCKS → V2Ray
///
/// Требования:
///   - AndroidManifest.xml: android:extractNativeLibs="true"
///   - build.gradle.kts: packaging { jniLibs { useLegacyPackaging = true } }
///   Иначе libtun2socks.so остаётся внутри APK и не может быть запущен.
class AndroidVpnBackend implements VpnBackend {
  static const _configKey = 'vpn_config';

  final _statusController = StreamController<BackendStatus>.broadcast();
  final _logController = StreamController<String>.broadcast();
  final _statsController = StreamController<VpnTrafficStats>.broadcast();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  @override
  Stream<BackendStatus> get statusStream => _statusController.stream;

  @override
  Stream<String> get logStream => _logController.stream;

  @override
  Stream<VpnTrafficStats> get statsStream => _statsController.stream;

  @override
  String get configUrl => _configUrl;

  String _configUrl = '';
  V2RayURL? _parser;

  late final FlutterV2ray _v2ray = FlutterV2ray(
    onStatusChanged: (status) {
      _emit(
        'STATUS: ${status.state}'
        '  ↑${status.upload} (${status.uploadSpeed})'
        '  ↓${status.download} (${status.downloadSpeed})',
      );
      _statsController.add(
        VpnTrafficStats(
          uploadBytes: status.upload.toString(),
          downloadBytes: status.download.toString(),
          uploadSpeed: status.uploadSpeed.toString(),
          downloadSpeed: status.downloadSpeed.toString(),
        ),
      );

      switch (status.state) {
        case 'CONNECTED':
          _statusController.add(BackendStatus.connected);
        case 'CONNECTING':
          _statusController.add(BackendStatus.connecting);
        case 'DISCONNECTED':
          _statusController.add(BackendStatus.disconnected);
        default:
          _emit('Unknown status: ${status.state}');
      }
    },
  );

  void _emit(String msg) {
    if (!_logController.isClosed) _logController.add(msg);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    _emit('Android backend init');
    try {
      await _v2ray.initializeV2Ray();
      _emit('flutter_v2ray initialized');

      final saved = await _readSavedConfig();
      if (saved.isNotEmpty) {
        await setConfig(saved);
      }
    } catch (e, stack) {
      _emit('INIT ERROR: $e');
      _emit(stack.toString());
    }
  }

  @override
  Future<void> setConfig(String url) async {
    final clean = url.trim();
    _configUrl = clean;

    try {
      final parser = FlutterV2ray.parseFromURL(clean);
      _parser = parser;
      _emit('Config parsed OK');

      await _secureStorage.write(key: _configKey, value: clean);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_configKey);
    } catch (e, stack) {
      _parser = null;
      _emit('Config error: $e');
      _emit(stack.toString());
      throw VpnConfigException(e.toString());
    }
  }

  // ── Ping ──────────────────────────────────────────────────────────────────

  @override
  Future<int> measurePing() async {
    if (_parser == null) return 0;
    try {
      final config = _prepareConfig();
      final delay = await _v2ray.getServerDelay(config: config);
      _emit('Ping: $delay ms');
      return delay;
    } catch (e) {
      _emit('Ping failed: $e');
      return 0;
    }
  }

  // ── Config ────────────────────────────────────────────────────────────────

  /// Подготавливает конфиг для V2Ray:
  /// 1. Убирает flow (xtls-rprx-vision несовместим с tun2socks)
  /// 2. Добавляет DNS outbound + routing rule для DNS-запросов
  /// 3. Прописывает DNS-серверы
  String _prepareConfig() {
    final parser = FlutterV2ray.parseFromURL(_configUrl);
    final config =
        jsonDecode(parser.getFullConfiguration()) as Map<String, dynamic>;

    // 1. Убираем flow из всех proxy-outbound
    final outbounds = config['outbounds'] as List? ?? [];
    for (final ob in outbounds) {
      if (ob is! Map) continue;
      final protocol = ob['protocol'] as String? ?? '';
      if (protocol == 'freedom' || protocol == 'blackhole') continue;

      final vnext = ob['settings']?['vnext'];
      if (vnext is List) {
        for (final server in vnext) {
          if (server is! Map) continue;
          final users = server['users'];
          if (users is! List) continue;
          for (final user in users) {
            if (user is Map) user.remove('flow');
          }
        }
      }
      break;
    }

    // 2. DNS outbound + routing
    outbounds.add({'tag': 'dns-out', 'protocol': 'dns'});

    final routing = config['routing'] as Map<String, dynamic>? ?? {};
    config['routing'] = routing;
    routing['domainStrategy'] = 'AsIs';
    final rules = routing['rules'] as List? ?? [];
    rules.insert(0, {'type': 'field', 'port': '53', 'outboundTag': 'dns-out'});
    routing['rules'] = rules;

    // 3. DNS серверы
    config['dns'] = {
      'servers': ['8.8.8.8', '1.1.1.1'],
      'queryStrategy': 'UseIPv4',
    };

    return jsonEncode(config);
  }

  // ── Connect / Disconnect ──────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    _emit('Connecting...');

    if (_configUrl.isEmpty || _parser == null) {
      _emit('Error: config is empty');
      _statusController.add(BackendStatus.error);
      return;
    }

    _statusController.add(BackendStatus.connecting);

    try {
      final configJson = _prepareConfig();

      final permission = await _v2ray.requestPermission();
      if (!permission) {
        _emit('VPN permission denied');
        _statusController.add(BackendStatus.disconnected);
        return;
      }

      final parser = FlutterV2ray.parseFromURL(_configUrl);
      final remark = _safeRemark(
        parser.remark,
        fallback: Uri.tryParse(_configUrl)?.host ?? 'VPN',
      );

      await _v2ray.startV2Ray(
        remark: remark,
        config: configJson,
        blockedApps: null,
        bypassSubnets: null,
        proxyOnly: false,
        notificationDisconnectButtonName: 'Отключить',
      );
      _emit('V2Ray started');
    } catch (e, stack) {
      _emit('Connect error: $e');
      _emit(stack.toString());
      _statusController.add(BackendStatus.error);
    }
  }

  @override
  Future<void> disconnect() async {
    _emit('Disconnecting...');
    try {
      await _v2ray.stopV2Ray();
      _emit('Disconnected');
    } catch (e, stack) {
      _emit('Disconnect error: $e');
      _emit(stack.toString());
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<String> _readSavedConfig() async {
    try {
      final secureValue = await _secureStorage.read(key: _configKey);
      if (secureValue != null && secureValue.isNotEmpty) {
        return secureValue;
      }
    } catch (e) {
      _emit('Secure storage read failed: $e');
    }

    final prefs = await SharedPreferences.getInstance();
    final legacyValue = prefs.getString(_configKey) ?? '';
    if (legacyValue.isNotEmpty) {
      try {
        await _secureStorage.write(key: _configKey, value: legacyValue);
        await prefs.remove(_configKey);
      } catch (e) {
        _emit('Secure storage migration failed: $e');
      }
    }
    return legacyValue;
  }

  /// Очищает remark от мусора в URL (хэш-суффиксы и т.п.)
  String _safeRemark(String value, {required String fallback}) {
    if (value.trim().isEmpty) return fallback;
    try {
      var decoded = Uri.decodeComponent(value.trim());
      final idx = decoded.lastIndexOf('-');
      if (idx > 0) {
        final suffix = decoded.substring(idx + 1);
        if (RegExp(r'^[a-z0-9]{6,14}$').hasMatch(suffix)) {
          decoded = decoded.substring(0, idx);
        }
      }
      return decoded.trim().isEmpty ? fallback : decoded.trim();
    } catch (_) {
      return value.trim();
    }
  }

  @override
  Future<void> dispose() async {
    await _statusController.close();
    await _logController.close();
    await _statsController.close();
  }
}
