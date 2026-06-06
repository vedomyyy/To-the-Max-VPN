import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'vpn_backend.dart';
import 'android_vpn_backend.dart';
import 'windows_vpn_backend.dart';

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

  // ── State ────────────────────────────────────────────────────────────────
  VpnStatus _status = VpnStatus.disconnected;
  int _ping = 0;
  final List<String> _logs = [];

  // ── Windows-specific: текущий режим ──────────────────────────────────────
  WindowsVpnMode _windowsMode = WindowsVpnMode.systemProxy;

  // ── Getters ───────────────────────────────────────────────────────────────
  VpnStatus get status => _status;
  bool get isConnected => _status == VpnStatus.connected;
  int get ping => _ping;
  List<String> get logs => List.unmodifiable(_logs);

  String get config => _backend.configUrl;

  /// Человекочитаемое имя сервера из конфига.
  String get serverName {
    final url = _backend.configUrl;
    if (url.isEmpty) return 'Не настроен';
    final uri = Uri.tryParse(url);
    final fragment = uri?.fragment ?? '';
    if (fragment.isNotEmpty) {
      try {
        return Uri.decodeComponent(fragment);
      } catch (_) {
        return fragment;
      }
    }
    return uri?.host ?? 'Сервер';
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
    if (_backend is WindowsVpnBackend) {
      (_backend as WindowsVpnBackend).mode = m;
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

    await _backend.initialize();
  }

  VpnBackend _createBackend() {
    if (Platform.isAndroid) return AndroidVpnBackend();
    if (Platform.isWindows) return WindowsVpnBackend(mode: _windowsMode);
    throw UnsupportedError('VPN не поддерживается на ${Platform.operatingSystem}');
  }

  // ── Public API ────────────────────────────────────────────────────────────

  void setConfig(String url) {
    _backend.setConfig(url).then((_) {
      notifyListeners();
    }).catchError((e) {
      _log('CONFIG ERROR: $e');
      notifyListeners();
    });
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

  @override
  void dispose() {
    _statusSub?.cancel();
    _logSub?.cancel();
    _backend.dispose();
    super.dispose();
  }
}