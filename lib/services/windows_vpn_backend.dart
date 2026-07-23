import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vpn_backend.dart';
import 'vpn_traffic_stats.dart';

/// Реализация VPN для Windows.
///
/// Архитектура:
///   Flutter UI
///     └─ WindowsVpnBackend
///           ├─ запускает bundled xray.exe с VLESS конфигом
///           │     └─ HTTP proxy на 127.0.0.1:10809
///           │     └─ SOCKS5 proxy на 127.0.0.1:10808
///           └─ выставляет Windows System Proxy через реестр
///
/// Режимы (переключаются через [mode]):
///   • [WindowsVpnMode.systemProxy]  — системный HTTP прокси (все браузеры,
///     большинство приложений). Не требует прав администратора.
///   • [WindowsVpnMode.tunTunnel]    — полный TUN туннель через tun2socks
///     (весь трафик ОС). Требует прав администратора + WinTUN драйвер.
///     Реализован в фазе 2 — сейчас бросает [UnimplementedError].
class WindowsVpnBackend implements VpnBackend {
  static const _configKey = 'vpn_config';
  static const _statsInterval = Duration(seconds: 1);
  static const _apiPort = 10085;

  WindowsVpnMode mode;

  WindowsVpnBackend({this.mode = WindowsVpnMode.systemProxy});

  // ── Streams ──────────────────────────────────────────────────────────────
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

  // ── Config state ─────────────────────────────────────────────────────────
  @override
  String get configUrl => _configUrl;

  String _configUrl = '';
  _ParsedVless? _parsed;

  // ── Process state ─────────────────────────────────────────────────────────
  Process? _xrayProcess;
  Process? _tun2socksProcess;
  String? _xrayPath;
  Timer? _statsTimer;
  int _lastRxBytes = 0;
  int _lastTxBytes = 0;
  DateTime? _lastStatsSampleAt;
  bool _proxyEnabled = false;
  bool _tunRouteAdded = false;
  // Имя TUN-адаптера, который поднимет tun2socks
  static const _tunName = 'tun0';

  // ── Logging ───────────────────────────────────────────────────────────────
  void _emit(String msg) {
    if (!_logController.isClosed) _logController.add(msg);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    _emit('========== WINDOWS BACKEND INITIALIZE ==========');
    _emit('Mode: ${mode.name}');

    try {
      // Извлекаем xray.exe из assets при первом запуске
      final xrayPath = await _ensureXrayExtracted();
      _emit('xray.exe path: $xrayPath');

      // Восстанавливаем сохранённый конфиг
      final saved = await _readSavedConfig();
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
    _emit('========== SET CONFIG ==========');
    _emit('URL: ${_maskConfigForLog(clean)}');

    final parsed = _ParsedVless.tryParse(clean);
    if (parsed == null) {
      _emit('ERROR: unsupported URL format (expected vless://)');
      throw VpnConfigException('Unsupported format. Only vless:// is supported on Windows.');
    }

    _configUrl = clean;
    _parsed = parsed;
    _emit('Parsed: host=${parsed.host} port=${parsed.port} uuid=${_maskUuid(parsed.uuid)}');
    _emit('Security: ${parsed.security}, type: ${parsed.type}, flow: ${parsed.flow.isEmpty ? "(none)" : parsed.flow}');
    _emit('SNI: ${parsed.sni.isEmpty ? "(none)" : parsed.sni}, fp: ${parsed.fp.isEmpty ? "(none)" : parsed.fp}');
    if (parsed.security == 'reality') {
      _emit('Reality pbk: ${parsed.pbk.isNotEmpty ? "OK (${parsed.pbk.length} chars)" : "⚠ MISSING — подключение не заработает!"}');
      _emit('Reality sid: ${parsed.sid.isNotEmpty ? "OK" : "⚠ MISSING — подключение не заработает!"}');
    }

    await _secureStorage.write(key: _configKey, value: clean);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_configKey);
  }

  @override
  Future<int> measurePing() async {
    if (_parsed == null) return 0;
    try {
      final stopwatch = Stopwatch()..start();
      final socket = await Socket.connect(
        _parsed!.host,
        _parsed!.port,
        timeout: const Duration(seconds: 5),
      );
      stopwatch.stop();
      socket.destroy();
      final ms = stopwatch.elapsedMilliseconds;
      _emit('TCP ping to ${_parsed!.host}:${_parsed!.port} = $ms ms');
      return ms;
    } catch (e) {
      _emit('Ping failed: $e');
      return 0;
    }
  }

  // ── Connect / Disconnect ──────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    _emit('========== CONNECT (Windows) ==========');

    if (_parsed == null) {
      _emit('ERROR: no config set');
      _statusController.add(BackendStatus.error);
      return;
    }

    _statusController.add(BackendStatus.connecting);

    try {
      await _startXray();
      // Ждём пока xray поднимет SOCKS5 (обычно < 500 мс)
      await Future.delayed(const Duration(milliseconds: 800));

      if (mode == WindowsVpnMode.systemProxy) {
        await _enableSystemProxy();
      } else {
        await _startTun();
      }

      _startStatsPolling();

      _statusController.add(BackendStatus.connected);
      _emit('VPN STATUS => CONNECTED');

      // Диагностический тест
      _runDiagnosticsDelayed();
    } catch (e, stack) {
      _emit('CONNECT ERROR: $e');
      _emit(stack.toString());
      await _cleanup();
      _statusController.add(BackendStatus.error);
    }
  }

  @override
  Future<void> disconnect() async {
    _emit('========== DISCONNECT (Windows) ==========');
    await _cleanup();
    _statusController.add(BackendStatus.disconnected);
    _emit('VPN STATUS => DISCONNECTED');
  }

  // ── xray process ──────────────────────────────────────────────────────────

  Future<void> _startXray() async {
    final xrayPath = await _ensureXrayExtracted();
    _xrayPath = xrayPath;
    final configPath = await _writeXrayConfig();

    // Убиваем любой зависший xray.exe перед запуском нового.
    // Без этого порт 10808 остаётся занятым и новый процесс падает сразу.
    _emit('Killing any existing xray.exe processes...');
    try {
      final kill = await Process.run('taskkill', ['/F', '/IM', 'xray.exe']);
      if (kill.exitCode == 0) {
        _emit('Killed existing xray.exe processes');
        // Небольшая пауза чтобы ОС освободила порт
        await Future.delayed(const Duration(milliseconds: 400));
      } else {
        _emit('No existing xray.exe found (ok)');
      }
    } catch (e) {
      _emit('WARNING: taskkill failed: $e');
    }

    _emit('Starting xray.exe...');
    _emit('Config: $configPath');

    // Проверяем что порт 10808 свободен перед запуском
    try {
      final server = await ServerSocket.bind('127.0.0.1', 10808);
      await server.close();
    } catch (e) {
      _emit('ERROR: Port 10808 still busy after cleanup: $e');
      _emit('Waiting extra 600ms for OS to release port...');
      await Future.delayed(const Duration(milliseconds: 600));
    }

    _xrayProcess = await Process.start(xrayPath, ['run', '-config', configPath]);

    // Буфер stderr — нужен чтобы поймать ошибку запуска конфига
    final stderrLines = <String>[];

    _xrayProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _emit('[xray] $line'));

    _xrayProcess!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _emit('[xray] $line');
      stderrLines.add(line);
    });

    // Ждём 1.2 сек: если xray упал сразу (ошибка конфига) — exitCode придёт быстро.
    // -1 = timeout = процесс жив = запуск успешен.
    final earlyExit = await _xrayProcess!.exitCode
        .timeout(const Duration(milliseconds: 1200), onTimeout: () => -1);

    if (earlyExit != -1) {
      final errorDetail = stderrLines
          .where((l) => l.toLowerCase().contains('failed') || l.toLowerCase().contains('error'))
          .join(' | ');
      _xrayProcess = null;
      throw Exception('xray.exe exited immediately (code $earlyExit): $errorDetail');
    }

    // Процесс жив — вешаем обработчик неожиданного завершения в будущем
    _xrayProcess!.exitCode.then((code) {
      _emit('xray.exe exited unexpectedly with code $code');
      _emit('Kill switch active: leaving proxy/routes in place until manual disconnect');
      // Сигналим UI что VPN отвалился
      _statusController.add(BackendStatus.disconnected);
    });

    _emit('xray.exe running (PID ${_xrayProcess!.pid})');
  }

  Future<String> _ensureXrayExtracted() async {
    final appDir = await getApplicationSupportDirectory();
    final xrayDir = Directory('${appDir.path}\\xray');
    await xrayDir.create(recursive: true);

    final xrayFile = File('${xrayDir.path}\\xray.exe');

    if (!xrayFile.existsSync()) {
      _emit('Extracting xray.exe from assets...');
      try {
        final data = await rootBundle.load('assets/xray/xray.exe');
        await xrayFile.writeAsBytes(data.buffer.asUint8List());
        _emit('Extracted: ${xrayFile.path} (${data.lengthInBytes} bytes)');
      } catch (e) {
        // В dev-режиме assets могут быть недоступны — ищем рядом с exe
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final devXray = File('$exeDir\\xray.exe');
        if (devXray.existsSync()) {
          _emit('Dev mode: using xray.exe from $exeDir');
          return devXray.path;
        }
        throw Exception(
          'xray.exe not found. '
          'Place it in assets/xray/xray.exe or next to the Flutter executable.\n'
          'Download: https://github.com/XTLS/Xray-core/releases/latest',
        );
      }
    }

    return xrayFile.path;
  }

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

  String _maskConfigForLog(String value) {
    try {
      final uri = Uri.parse(value);
      final user = uri.userInfo;
      final safeUser = user.isEmpty ? '' : '${_maskUuid(user)}@';
      final host = uri.host;
      final port = uri.hasPort ? ':${uri.port}' : '';
      return '${uri.scheme}://$safeUser$host$port?...';
    } catch (_) {
      return '***';
    }
  }

  String _maskUuid(String value) {
    if (value.length <= 8) return '***';
    return '${value.substring(0, 4)}...${value.substring(value.length - 4)}';
  }

  // ── TUN tunnel (tun2socks + WinTUN) ──────────────────────────────────────

  /// Извлекаем tun2socks.exe и wintun.dll из assets аналогично xray.exe.
  Future<String> _ensureTun2socksExtracted() async {
    final appDir = await getApplicationSupportDirectory();
    final tunDir = Directory('${appDir.path}\\tun2socks');
    await tunDir.create(recursive: true);

    // tun2socks.exe
    final exeFile = File('${tunDir.path}\\tun2socks.exe');
    if (!exeFile.existsSync()) {
      _emit('Extracting tun2socks.exe from assets...');
      final data = await rootBundle.load('assets/tun2socks/tun2socks.exe');
      await exeFile.writeAsBytes(data.buffer.asUint8List());
      _emit('Extracted tun2socks.exe (${data.lengthInBytes} bytes)');
    }

    // wintun.dll — лежит рядом, обязательна для WinTUN
    final dllFile = File('${tunDir.path}\\wintun.dll');
    if (!dllFile.existsSync()) {
      _emit('Extracting wintun.dll from assets...');
      final data = await rootBundle.load('assets/tun2socks/wintun.dll');
      await dllFile.writeAsBytes(data.buffer.asUint8List());
      _emit('Extracted wintun.dll (${data.lengthInBytes} bytes)');
    }

    return exeFile.path;
  }

  /// Запускает tun2socks, настраивает маршрутизацию через TUN-адаптер.
  ///
  /// Требует прав администратора (UAC manifest: requireAdministrator).
  /// После запуска весь IP-трафик ОС идёт в xray SOCKS5 на 127.0.0.1:10808.
  Future<void> _startTun() async {
    _emit('========== TUN START ==========');

    final tun2socksPath = await _ensureTun2socksExtracted();
    final serverIp = _parsed!.host;

    _emit('tun2socks path: $tun2socksPath');
    _emit('Server IP (will be bypassed): $serverIp');

    // Запускаем tun2socks:
    //   --device  — имя TUN-адаптера (создаётся автоматически через WinTUN)
    //   --proxy   — наш xray SOCKS5
    //   --loglevel — warn чтобы не спамить
    _tun2socksProcess = await Process.start(
      tun2socksPath,
      [
        '--device', _tunName,
        '--proxy', 'socks5://127.0.0.1:10808',
        '--loglevel', 'warn',
      ],
    );

    _tun2socksProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _emit('[tun2socks] $line'));

    _tun2socksProcess!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _emit('[tun2socks] $line'));

    // Ранний выход = ошибка (нет прав, нет wintun.dll и т.д.)
    final earlyExit = await _tun2socksProcess!.exitCode
        .timeout(const Duration(milliseconds: 1500), onTimeout: () => -1);

    if (earlyExit != -1) {
      _tun2socksProcess = null;
      throw Exception(
        'tun2socks.exe exited immediately (code $earlyExit). '
        'Убедитесь что приложение запущено от имени администратора и wintun.dll рядом с tun2socks.exe.',
      );
    }

    _emit('tun2socks running (PID ${_tun2socksProcess!.pid})');

    // Ждём пока адаптер поднимется
    await Future.delayed(const Duration(milliseconds: 500));

    _resetStatsBaseline();

    // Настраиваем адаптер через netsh и добавляем маршруты
    await _configureTunAdapter(serverIp);

    // Следим за неожиданным завершением
    _tun2socksProcess!.exitCode.then((code) {
      _emit('tun2socks.exe exited with code $code');
      _emit('Kill switch active: keeping TUN routes in place until manual disconnect');
      _statusController.add(BackendStatus.disconnected);
    });
  }

  /// Назначает IP TUN-адаптеру и добавляет маршруты.
  Future<void> _configureTunAdapter(String serverIp) async {
  _emit('Configuring TUN adapter...');

  // Назначаем IP адаптеру
  await _netsh([
    'interface', 'ip', 'set', 'address',
    'name=tun0', 'static', '10.0.0.1', '255.255.255.252',
  ]);
  _emit('TUN adapter IP: 10.0.0.1/30');

  // Ждём пока адаптер поднимется с IP
  await Future.delayed(const Duration(milliseconds: 800));

  // Узнаём индекс интерфейса tun0
  final ifIndex = await _getTunIfIndex();
  _emit('TUN interface index: $ifIndex');

  final gateway = await _getDefaultGateway();
  _emit('Current default gateway: $gateway');

  // Bypass: сервер VPN напрямую через реальный шлюз
  await _route(['add', serverIp, 'mask', '255.255.255.255', gateway]);
  _emit('Added bypass route: $serverIp → $gateway');

  // Весь трафик через TUN — используем if вместо шлюза
  await _route(['add', '0.0.0.0', 'mask', '0.0.0.0', '10.0.0.2', 'if', ifIndex, 'metric', '1']);
  _emit('Added default route via tun0 (if $ifIndex)');

  // DNS на TUN интерфейс — xray будет резолвить
  await _netsh([
    'interface', 'ip', 'set', 'dns',
    'name=tun0', 'static', '1.1.1.1',
  ]);
  _emit('DNS set to 1.1.1.1 on tun0');

  _tunRouteAdded = true;
  _emit('TUN routing configured');
}

Future<String> _getTunIfIndex() async {
  try {
    final result = await Process.run('powershell', [
      '-NoProfile', '-Command',
      '(Get-NetAdapter | Where-Object { \$_.Name -eq "tun0" }).ifIndex',
    ]);
    return result.stdout.toString().trim();
  } catch (e) {
    _emit('WARNING: cannot get tun0 index: $e');
    return '0';
  }
}

  /// Откатываем маршруты при отключении.
  Future<void> _removeTunRoutes(String serverIp) async {
  _emit('Removing TUN routes...');
  try {
    await _route(['delete', serverIp, 'mask', '255.255.255.255']);
  } catch (e) {
    _emit('WARNING: cannot remove server route: $e');
  }
  try {
    await _route(['delete', '0.0.0.0', 'mask', '0.0.0.0']);
  } catch (e) {
    _emit('WARNING: cannot remove default route: $e');
  }
  _tunRouteAdded = false;
  _emit('TUN routes removed');
}

  /// Читает шлюз по умолчанию через `route print`.
  Future<String> _getDefaultGateway() async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile', '-Command',
        '(Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1).NextHop',
      ]);
      final gw = result.stdout.toString().trim();
      if (gw.isNotEmpty && gw != '0.0.0.0') return gw;
    } catch (_) {}
    return '192.168.1.1'; // fallback
  }

  Future<void> _netsh(List<String> args) async {
    final result = await Process.run('netsh', args, runInShell: true);
    if (result.exitCode != 0) {
      _emit('WARNING: netsh ${args.join(' ')} → exitCode ${result.exitCode}: ${result.stderr}');
    }
  }

  Future<void> _route(List<String> args) async {
    final result = await Process.run('route', args, runInShell: true);
    if (result.exitCode != 0) {
      throw Exception('route ${args.join(' ')} failed (${result.exitCode}): ${result.stderr}');
    }
  }

  Future<String> _writeXrayConfig() async {
    final p = _parsed!;
    final appDir = await getApplicationSupportDirectory();
    final configFile = File('${appDir.path}\\xray\\config.json');

    // Классический Xray v5 конфиг
    final config =
     {
      'log': {'loglevel': 'warning'},
      'stats': {},
      'api': {
        'tag': 'api',
        'listen': '127.0.0.1:$_apiPort',
        'services': ['StatsService'],
      },
      'policy': {
        'levels': {
          '0': {
            'statsUserUplink': false,
            'statsUserDownlink': false,
            'statsUserOnline': false,
            'bufferSize': 4,
          },
        },
        'system': {
          'statsInboundUplink': false,
          'statsInboundDownlink': false,
          'statsOutboundUplink': true,
          'statsOutboundDownlink': true,
        },
      },
      'dns': {
        'servers': ['1.1.1.1', '8.8.8.8'],
      },
      'inbounds': [
        {
          'tag': 'socks-in',
          'port': 10808,
          'listen': '127.0.0.1',
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true},
          'sniffing': {'enabled': true, 'destOverride': ['http', 'tls', 'quic']},
        },
        {
          'tag': 'http-in',
          'port': 10809,
          'listen': '127.0.0.1',
          'protocol': 'http',
          'settings': {},
          'sniffing': {'enabled': true, 'destOverride': ['http', 'tls']},
        },
      ],
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': p.host,
                'port': p.port,
                'users': [
                  {
                    'id': p.uuid,
                    'encryption': 'none',
                    // flow добавляем ТОЛЬКО если задан (пустая строка вызывает ошибку xray при Reality)
                    // flow отключаем при mux — они несовместимы
                    // if (p.flow.isNotEmpty) 'flow': p.flow,
                  }
                ],
              }
            ],
          },
          'mux': {
              'enabled': true,
              'concurrency': 8,
          },
          'streamSettings': {
            'network': p.type,         // 'tcp', 'ws', 'grpc' и т.д.
            'security': p.security,    // 'none', 'tls', 'reality'
            // TLS/Reality settings добавляются динамически ниже
            ..._buildStreamExtra(p),
          },
        },
        {
          'tag': 'direct',
          'protocol': 'freedom',
          'settings': {'domainStrategy': 'UseIP'},
        },
        {
          'tag': 'block',
          'protocol': 'blackhole',
          'settings': {'response': {'type': 'http'}},
        },
      ],
      'routing': {
  'domainStrategy': 'IPIfNonMatch',
  'rules': [
    // Блокируем NetBIOS и mDNS — они флудят TUN при старте
    {
      'type': 'field',
      'outboundTag': 'block',
      'network': 'udp',
      'port': '137-139,5353',
    },
    // Сервер — всегда напрямую (защита от петли)
    {
      'type': 'field',
      'ip': ['${p.host}/32'],
      'outboundTag': 'direct',
    },
    // Локальные адреса — напрямую
    {
      'type': 'field',
      'ip': [
        '127.0.0.0/8',
        '10.0.0.0/8',
        '172.16.0.0/12',
        '192.168.0.0/16',
        '169.254.0.0/16',
        '::1/128',
        'fc00::/7',
        'fe80::/10',
      ],
      'outboundTag': 'direct',
    },
    // Всё остальное — через прокси
    {
      'type': 'field',
      'outboundTag': 'proxy',
      'network': 'tcp,udp',
    },
  ],
},
    };

    final jsonStr = const JsonEncoder.withIndent('  ').convert(config);
    await configFile.writeAsString(jsonStr);
    _emit('Config written (${jsonStr.length} chars)');
    return configFile.path;
  }

  Map<String, dynamic> _buildStreamExtra(_ParsedVless p) {
    if (p.security == 'tls') {
      return {
        'tlsSettings': {
          'allowInsecure': false,
          'serverName': p.sni.isEmpty ? p.host : p.sni,
        },
      };
    }
    if (p.security == 'reality') {
      return {
        'realitySettings': {
          'serverName': p.sni,
          'fingerprint': p.fp.isEmpty ? 'chrome' : p.fp,
          'publicKey': p.pbk,
          'shortId': p.sid,
          'spiderX': '',
        },
      };
    }
    // none / raw — никаких доп. настроек
    return {};
  }

  // ── System Proxy ──────────────────────────────────────────────────────────

  static const _regPath =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  Future<void> _enableSystemProxy() async {
    _emit('Enabling system proxy: 127.0.0.1:10809');
    await _reg(['add', _regPath, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']);
    await _reg(['add', _regPath, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', '127.0.0.1:10809', '/f']);
    // Bypass localhost и LAN
    await _reg([
      'add', _regPath, '/v', 'ProxyOverride',
      '/t', 'REG_SZ', '/d', 'localhost;127.*;10.*;172.16.*;192.168.*;<local>', '/f'
    ]);
    await _notifyProxyChange();
    _proxyEnabled = true;
    _emit('System proxy enabled');
  }

  Future<void> _disableSystemProxy() async {
    _emit('Disabling system proxy...');
    await _reg(['add', _regPath, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
    await _notifyProxyChange();
    _proxyEnabled = false;
    _emit('System proxy disabled');
  }

  Future<void> _reg(List<String> args) async {
    final result = await Process.run('reg', args);
    if (result.exitCode != 0) {
      throw Exception('reg.exe failed (${result.exitCode}): ${result.stderr}');
    }
  }

  /// Уведомляем WinINet об изменении настроек прокси через PowerShell.
  /// Без этого браузеры подхватят прокси только после перезапуска.
  Future<void> _notifyProxyChange() async {
    const script = r'''
$sig = '[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
$t = Add-Type -MemberDefinition $sig -Name WI -Namespace WI -PassThru
$t::InternetSetOption(0,39,[IntPtr]::Zero,0)  # INTERNET_OPTION_SETTINGS_CHANGED
$t::InternetSetOption(0,37,[IntPtr]::Zero,0)  # INTERNET_OPTION_REFRESH
''';
    final result = await Process.run('powershell', ['-NoProfile', '-Command', script]);
    if (result.exitCode != 0) {
      _emit('WARNING: proxy refresh notification failed: ${result.stderr}');
    }
  }

  // ── Diagnostics ───────────────────────────────────────────────────────────

  void _runDiagnosticsDelayed() {
    Future.delayed(const Duration(seconds: 2), _testConnection);
  }

  Future<void> _testConnection() async {
    _emit('========== DIAGNOSTICS ==========');
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..findProxy = (_) => 'PROXY 127.0.0.1:10809';

      final req = await client
          .getUrl(Uri.parse('http://api.ipify.org/'))
          .timeout(const Duration(seconds: 10));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await utf8.decoder.bind(resp).join().timeout(const Duration(seconds: 10));
      final ip = body.trim();
      _emit('External IP (via xray proxy): $ip');
      if (_parsed != null && ip.contains(_parsed!.host)) {
        _emit('✓ ТРАФИК ИДЁТ ЧЕРЕЗ VPN SERVER');
      } else {
        _emit('? IP не совпадает с сервером — возможно NAT или CDN');
      }
    } catch (e) {
      _emit('Diagnostics failed: $e');
    } finally {
      client?.close(force: true);
    }
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  Future<void> _cleanup() async {
    _stopStatsPolling();
    if (_proxyEnabled) {
      await _disableSystemProxy().onError((e, _) => _emit('ERROR disabling proxy: $e'));
    }
    if (_tunRouteAdded && _parsed != null) {
      await _removeTunRoutes(_parsed!.host).onError((e, _, ) => _emit('ERROR removing routes: $e'));
    }
    if (_tun2socksProcess != null) {
      _emit('Killing tun2socks.exe (PID ${_tun2socksProcess!.pid})...');
      _tun2socksProcess!.kill(ProcessSignal.sigterm);
      await Future.delayed(const Duration(milliseconds: 200));
      _tun2socksProcess!.kill();
      _tun2socksProcess = null;
    }
    if (_xrayProcess != null) {
      _emit('Killing xray.exe (PID ${_xrayProcess!.pid})...');
      _xrayProcess!.kill(ProcessSignal.sigterm);
      // На Windows SIGTERM игнорируется — принудительно
      await Future.delayed(const Duration(milliseconds: 200));
      _xrayProcess!.kill();
      _xrayProcess = null;
    }
  }

  @override
  Future<void> dispose() async {
    await _cleanup();
    await _statusController.close();
    await _logController.close();
    await _statsController.close();
  }

  void _startStatsPolling() {
    if (_xrayPath == null) return;
    _stopStatsPolling();
    _statsTimer = Timer.periodic(_statsInterval, (_) => _pollTunStats());
    _emit('Windows stats polling started via Xray API');
  }

  void _stopStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastStatsSampleAt = null;
    _lastRxBytes = 0;
    _lastTxBytes = 0;
  }

  void _resetStatsBaseline() {
    _lastStatsSampleAt = DateTime.now();
    _lastRxBytes = 0;
    _lastTxBytes = 0;
  }

  Future<void> _pollTunStats() async {
    if (_statsController.isClosed || _xrayPath == null) return;
    try {
      final result = await Process.run(_xrayPath!, [
        'api',
        'statsquery',
        '--server=127.0.0.1:$_apiPort',
        '-pattern',
        'outbound>>>proxy>>>traffic>>>',
      ]);

      if (result.exitCode != 0) {
        _emit('WARNING: xray stats query failed: ${result.stderr}');
        return;
      }

      final raw = result.stdout.toString().trim();
      if (raw.isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final stats = decoded['stat'];
      if (stats is! List) return;

      int rxBytes = 0;
      int txBytes = 0;
      for (final entry in stats) {
        if (entry is! Map) continue;
        final name = entry['name']?.toString() ?? '';
        final value = int.tryParse(entry['value'].toString()) ?? 0;
        if (name == 'outbound>>>proxy>>>traffic>>>downlink') {
          rxBytes = value;
        } else if (name == 'outbound>>>proxy>>>traffic>>>uplink') {
          txBytes = value;
        }
      }
      final now = DateTime.now();

      double seconds = 1;
      if (_lastStatsSampleAt != null) {
        seconds = now.difference(_lastStatsSampleAt!).inMilliseconds / 1000;
        if (seconds <= 0) seconds = 1;
      }

      final rxDelta = rxBytes >= _lastRxBytes ? rxBytes - _lastRxBytes : 0;
      final txDelta = txBytes >= _lastTxBytes ? txBytes - _lastTxBytes : 0;

      _lastRxBytes = rxBytes;
      _lastTxBytes = txBytes;
      _lastStatsSampleAt = now;

      _statsController.add(
        VpnTrafficStats(
          uploadBytes: _formatBytes(txBytes),
          downloadBytes: _formatBytes(rxBytes),
          uploadSpeed: _formatRate(txDelta / seconds),
          downloadSpeed: _formatRate(rxDelta / seconds),
        ),
      );
    } catch (e) {
      _emit('WARNING: xray stats polling error: $e');
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final fractionDigits = value >= 10 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(fractionDigits)} ${units[unit]}';
  }

  String _formatRate(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0 B/s';
    return '${_formatBytes(bytesPerSecond.round())}/s';
  }
}

enum WindowsVpnMode {
  /// HTTP/SOCKS прокси через реестр Windows. Работает в браузерах и
  /// большинстве приложений. Не требует прав администратора.
  systemProxy,

  /// Полный TUN туннель через tun2socks + WinTUN драйвер.
  /// Требует прав администратора. Планируется в фазе 2.
  tunTunnel,
}

// ── VLESS URL parser ──────────────────────────────────────────────────────────

class _ParsedVless {
  final String uuid;
  final String host;
  final int port;
  final String type;       // tcp | ws | grpc | ...
  final String security;   // none | tls | reality
  final String flow;
  final String sni;
  final String fp;         // fingerprint (reality)
  final String pbk;        // publicKey (reality)
  final String sid;        // shortId (reality)

  const _ParsedVless({
    required this.uuid,
    required this.host,
    required this.port,
    required this.type,
    required this.security,
    required this.flow,
    required this.sni,
    required this.fp,
    required this.pbk,
    required this.sid,
  });

  static _ParsedVless? tryParse(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'vless') return null;

      final q = uri.queryParameters;
      return _ParsedVless(
        uuid: uri.userInfo,
        host: uri.host,
        port: uri.port,
        type: q['type'] ?? 'tcp',
        security: q['security'] ?? 'none',
        flow: q['flow'] ?? '',
        sni: q['sni'] ?? '',
        fp: q['fp'] ?? '',
        pbk: q['pbk'] ?? '',
        sid: q['sid'] ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}