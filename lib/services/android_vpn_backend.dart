import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vpn_backend.dart';

/// Реализация VPN через flutter_v2ray (только Android).
/// Весь код перенесён из оригинального vpn_service.dart без изменений логики.
class AndroidVpnBackend implements VpnBackend {
  final _statusController = StreamController<BackendStatus>.broadcast();
  final _logController = StreamController<String>.broadcast();

  @override
  Stream<BackendStatus> get statusStream => _statusController.stream;

  @override
  Stream<String> get logStream => _logController.stream;

  @override
  String get configUrl => _configUrl;

  String _configUrl = '';
  V2RayURL? _parser;

  late final FlutterV2ray _v2ray = FlutterV2ray(
    onStatusChanged: (status) {
      _emit('========== STATUS CALLBACK ==========');
      _emit('Raw status: ${status.state}');
      _emit('Upload: ${status.upload}');
      _emit('Download: ${status.download}');
      _emit('Upload speed: ${status.uploadSpeed}');
      _emit('Download speed: ${status.downloadSpeed}');

      switch (status.state) {
        case 'CONNECTED':
          _statusController.add(BackendStatus.connected);
          _emit('VPN STATUS => CONNECTED');
        case 'CONNECTING':
          _statusController.add(BackendStatus.connecting);
          _emit('VPN STATUS => CONNECTING');
        case 'DISCONNECTED':
          _statusController.add(BackendStatus.disconnected);
          _emit('VPN STATUS => DISCONNECTED');
        default:
          _emit('UNKNOWN STATUS => ${status.state}');
      }
    },
  );

  void _emit(String msg) {
    if (!_logController.isClosed) _logController.add(msg);
  }

  @override
  Future<void> initialize() async {
    _emit('========== ANDROID BACKEND INITIALIZE ==========');
    try {
      await _v2ray.initializeV2Ray();
      _emit('flutter_v2ray initialized');

      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('vpn_config') ?? '';
      if (saved.isNotEmpty) {
        _emit('Restoring saved config...');
        await setConfig(saved);
      }
    } catch (e, stack) {
      _emit('INITIALIZATION ERROR: $e');
      _emit(stack.toString());
    }
  }

  @override
  Future<void> setConfig(String url) async {
    final clean = url.trim();
    _configUrl = clean;

    _emit('========== SET CONFIG ==========');
    _emit('Config length: ${clean.length}');

    try {
      final parser = FlutterV2ray.parseFromURL(clean);
      _parser = parser;
      _emit('Config parsed OK');
      _logStreamSettings(parser.getFullConfiguration());

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vpn_config', clean);
    } catch (e, stack) {
      _parser = null;
      _emit('CONFIG PARSE ERROR: $e');
      _emit(stack.toString());
      throw VpnConfigException(e.toString());
    }
  }

  void _logStreamSettings(String jsonConfig) {
    try {
      final decoded = jsonDecode(jsonConfig) as Map<String, dynamic>;
      final outbounds = decoded['outbounds'];
      if (outbounds is! List || outbounds.isEmpty) {
        _emit('WARNING: config has no outbounds');
        return;
      }
      final proxy = outbounds.firstWhere(
        (o) => o is Map && o['protocol'] != 'freedom' && o['protocol'] != 'blackhole',
        orElse: () => outbounds.first,
      );
      if (proxy is! Map) return;
      _emit('Outbound protocol: ${proxy['protocol']}');
      final ss = proxy['streamSettings'];
      if (ss is Map) {
        _emit('Network: ${ss['network']}');
        _emit('Security: ${ss['security']}');
      }
    } catch (e) {
      _emit('WARNING: cannot inspect JSON: $e');
    }
  }

  @override
  Future<int> measurePing() async {
    if (_parser == null) return 0;
    try {
      final config = _buildFullConfig();
      final delay = await _v2ray.getServerDelay(config: jsonEncode(config));
      _emit('Server delay: $delay ms');
      return delay;
    } catch (e) {
      _emit('WARNING: ping check failed: $e');
      return 0;
    }
  }

  @override
  Future<void> connect() async {
    _emit('========== CONNECT ==========');

    if (_configUrl.isEmpty) {
      _emit('ERROR: CONFIG IS EMPTY');
      _statusController.add(BackendStatus.error);
      return;
    }
    if (_parser == null) {
      _emit('ERROR: CONFIG NOT PARSED');
      _statusController.add(BackendStatus.error);
      return;
    }

    _statusController.add(BackendStatus.connecting);

    try {
      final fullConfig = _buildFullConfig();
      final jsonConfig = jsonEncode(fullConfig);

      _emit('JSON config built (${jsonConfig.length} chars)');
      _logStreamSettings(jsonConfig);

      _emit('Requesting VPN permission...');
      final permission = await _v2ray.requestPermission();
      _emit('Permission result: $permission');

      if (!permission) {
        _emit('VPN PERMISSION DENIED');
        _statusController.add(BackendStatus.disconnected);
        return;
      }

      final bypassSubnets = await _buildServerBypassSubnets();
      _emit('Bypass subnets: ${bypassSubnets.isEmpty ? 'none' : bypassSubnets.join(', ')}');

      final parser = FlutterV2ray.parseFromURL(_configUrl);
      final remark = _safeRemark(parser.remark, fallback: Uri.tryParse(_configUrl)?.host ?? 'server');

      await _v2ray.startV2Ray(
        remark: remark,
        config: jsonConfig,
        blockedApps: null,
        bypassSubnets: bypassSubnets.isEmpty ? null : bypassSubnets,
        proxyOnly: false,
      );

      _emit('startV2Ray() called — waiting for status callback...');
    } catch (e, stack) {
      _emit('CONNECT ERROR: $e');
      _emit(stack.toString());
      _statusController.add(BackendStatus.error);
    }
  }

  Map<String, dynamic> _buildFullConfig() {
    final parser = FlutterV2ray.parseFromURL(_configUrl);
    final generated = jsonDecode(parser.getFullConfiguration()) as Map<String, dynamic>;
    final outbounds = generated['outbounds'] as List<dynamic>;
    final proxyOutbound = outbounds.firstWhere(
      (o) => o is Map && o['tag'] == 'proxy',
      orElse: () => outbounds.first,
    );

    return {
      'log': {'loglevel': 'debug'},
      'dns': {
        'servers': ['1.1.1.1', '8.8.8.8', 'localhost'],
      },
      'inbounds': [
        {
          'tag': 'socks',
          'port': 10808,
          'listen': '127.0.0.1',
          'protocol': 'socks',
          'sniffing': {'enabled': true, 'destOverride': ['http', 'tls']},
          'settings': {'auth': 'noauth', 'udp': true},
        },
        {
          'tag': 'http',
          'port': 10809,
          'listen': '127.0.0.1',
          'protocol': 'http',
          'sniffing': {'enabled': true, 'destOverride': ['http', 'tls']},
          'settings': {'userLevel': 8},
        },
      ],
      'outbounds': [
        proxyOutbound,
        {'tag': 'direct', 'protocol': 'freedom', 'settings': {}},
        {'tag': 'block', 'protocol': 'blackhole', 'settings': {'response': {'type': 'http'}}},
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          {'type': 'field', 'outboundTag': 'proxy', 'network': 'tcp,udp'},
        ],
      },
    };
  }

  Future<List<String>> _buildServerBypassSubnets() async {
    try {
      final host = Uri.tryParse(_configUrl)?.host.trim() ?? '';
      if (host.isEmpty) return [];

      final parsed = InternetAddress.tryParse(host);
      if (parsed != null) return [_subnet(parsed)];

      final addresses = await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
      return addresses.map(_subnet).toSet().toList();
    } catch (e) {
      _emit('WARNING: cannot build bypass subnets: $e');
      return [];
    }
  }

  String _subnet(InternetAddress addr) =>
      addr.type == InternetAddressType.IPv6 ? '${addr.address}/128' : '${addr.address}/32';

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
  Future<void> disconnect() async {
    _emit('========== DISCONNECT ==========');
    try {
      await _v2ray.stopV2Ray();
      _emit('stopV2Ray() completed');
    } catch (e, stack) {
      _emit('DISCONNECT ERROR: $e');
      _emit(stack.toString());
    }
  }

  @override
  Future<void> dispose() async {
    await _statusController.close();
    await _logController.close();
  }
}