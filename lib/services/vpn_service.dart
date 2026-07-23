import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'vpn_backend.dart';
import 'android_vpn_backend.dart';
import 'windows_vpn_backend.dart';
import 'vpn_traffic_stats.dart';

export 'vpn_backend.dart' show VpnConfigException;
export 'windows_vpn_backend.dart' show WindowsVpnMode;

/// Статус VPN — публичный enum для UI.
enum VpnStatus { disconnected, connecting, connected, error }

/// Фасад VPN-сервиса. Автоматически выбирает платформенный бэкенд:
///   • Android → [AndroidVpnBackend] (flutter_v2ray)
///   • Windows → [WindowsVpnBackend] (xray.exe + system proxy / TUN)
///
/// UI работает только с этим классом — менять ничего не нужно.
class VpnService extends ChangeNotifier {
  // ── Backend ──────────────────────────────────────────────────────────────
  late final VpnBackend _backend;

  StreamSubscription<BackendStatus>? _statusSub;
  StreamSubscription<String>? _logSub;
  StreamSubscription<VpnTrafficStats>? _statsSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isShuttingDown = false;
  bool _reconnectPending = false;
  bool _reconnectInProgress = false;

  // ── State ────────────────────────────────────────────────────────────────
  VpnStatus _status = VpnStatus.disconnected;
  int _ping = 0;
  VpnTrafficStats _traffic = VpnTrafficStats.zero;
  final List<String> _logs = [];

  // ── Windows-specific: текущий режим ──────────────────────────────────────
  WindowsVpnMode _windowsMode = WindowsVpnMode.systemProxy;

  // ── Getters ───────────────────────────────────────────────────────────────
  VpnStatus get status => _status;
  bool get isConnected => _status == VpnStatus.connected;
  int get ping => _ping;
  VpnTrafficStats get traffic => _traffic;
  List<String> get logs => List.unmodifiable(_logs);

  String get config => _backend.configUrl;

  /// Человекочитаемое имя сервера из конфига.
  /// Показывает IP-адрес (компактно и однозначно).
  /// Полное имя (из фрагмента ссылки) доступно через [serverLabel].
  String get serverName {
    final url = _backend.configUrl;
    if (url.isEmpty) return 'Не настроен';
    final uri = Uri.tryParse(url);
    if (uri == null) return 'Сервер';
    // Показываем IP:port (или просто IP если порт стандартный 443)
    final host = uri.host;
    final port = uri.port;
    if (host.isEmpty) return 'Сервер';
    return port == 443 ? host : '$host:$port';
  }

  /// Полное имя сервера из фрагмента VLESS-ссылки (если есть).
  /// Используется для тултипов / деталей.
  String get serverLabel {
    final url = _backend.configUrl;
    if (url.isEmpty) return '';
    final uri = Uri.tryParse(url);
    final fragment = uri?.fragment ?? '';
    if (fragment.isNotEmpty) {
      try {
        return Uri.decodeComponent(fragment);
      } catch (_) {
        return fragment;
      }
    }
    return '';
  }

  /// Протокол из конфига.
  String get protocol {
    final url = _backend.configUrl;
    if (url.isEmpty) return '—';
    return (Uri.tryParse(url)?.scheme ?? 'unknown').toUpperCase();
  }

  /// Только Windows: переключить режим proxy ↔ TUN.
  WindowsVpnMode get windowsMode => _windowsMode;
  set windowsMode(WindowsVpnMode m) {
    if (_backend case final WindowsVpnBackend backend) {
      backend.mode = m;
      _windowsMode = m;
      notifyListeners();
    }
  }

  /// true если работаем на Windows.
  bool get isWindows => Platform.isWindows;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    _backend = _createBackend();
    _log('Platform: ${Platform.operatingSystem}');
    _log('Backend: ${_backend.runtimeType}');

    _statusSub = _backend.statusStream.listen(_onBackendStatus);
    _logSub = _backend.logStream.listen(_onBackendLog);
    _statsSub = _backend.statsStream.listen(_onBackendStats);
    _connectivitySub = Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);

    await _backend.initialize();
  }

  VpnBackend _createBackend() {
    if (Platform.isAndroid) return AndroidVpnBackend();
    if (Platform.isWindows) return WindowsVpnBackend(mode: _windowsMode);
    throw UnsupportedError('VPN не поддерживается на ${Platform.operatingSystem}');
  }

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> setConfig(String url) async {
    try {
      await _backend.setConfig(url);
      notifyListeners();
    } catch (e) {
      _log('CONFIG ERROR: $e');
      notifyListeners();
      rethrow;
    }
  }

  Future<void> toggle() async {
    if (_status == VpnStatus.connected) {
      await _backend.disconnect();
    } else if (_status == VpnStatus.disconnected || _status == VpnStatus.error) {
      _ping = 0;
      notifyListeners();
      // Измеряем пинг параллельно с подключением
      _backend.measurePing().then((ms) {
        _ping = ms;
        notifyListeners();
      });
      await _backend.connect();
    }
  }

  Future<void> reconnect() async {
    if (_reconnectInProgress || _isShuttingDown) return;
    _reconnectInProgress = true;
    try {
      _log('Network changed, reconnecting VPN...');
      try {
        await _backend.disconnect();
      } catch (e) {
        _log('Reconnect cleanup warning: $e');
      }
      await Future.delayed(const Duration(milliseconds: 500));
      await _backend.connect();
    } finally {
      _reconnectInProgress = false;
      _reconnectPending = false;
    }
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _onBackendStatus(BackendStatus s) {
    _status = switch (s) {
      BackendStatus.disconnected => VpnStatus.disconnected,
      BackendStatus.connecting   => VpnStatus.connecting,
      BackendStatus.connected    => VpnStatus.connected,
      BackendStatus.error        => VpnStatus.error,
    };
    if (_status == VpnStatus.disconnected) _ping = 0;
    notifyListeners();
  }

  void _onBackendLog(String line) {
    _log(line, fromBackend: true);
  }

  void _onBackendStats(VpnTrafficStats stats) {
    _traffic = stats;
    notifyListeners();
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (_isShuttingDown) return;

    final hasNetwork = results.any((result) => result != ConnectivityResult.none);
    if (!hasNetwork) {
      if (_status == VpnStatus.connected) {
        _reconnectPending = true;
        _log('Network lost, waiting for reconnect...');
      }
      return;
    }

    if (_reconnectPending || _status == VpnStatus.connected) {
      unawaited(reconnect());
    }
  }

  void _log(String message, {bool fromBackend = false}) {
    final time = DateTime.now().toString().substring(11, 19);
    // Бэкенды не добавляют время — добавляем здесь.
    // Если строка уже со временем (из старого кода) — не дублируем.
    final line = fromBackend ? '[$time] $message' : '[$time] $message';

    _logs.add(line);
    debugPrint(line);
    if (_logs.length > 500) _logs.removeAt(0);
    notifyListeners();
  }

  Future<void> shutdown() async {
    if (_isShuttingDown) return;
    _isShuttingDown = true;

    await _statusSub?.cancel();
    await _logSub?.cancel();
    await _statsSub?.cancel();
    await _connectivitySub?.cancel();
    await _backend.dispose();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}