import 'dart:io';

import 'package:flutter/material.dart';
import '../services/vpn_service.dart';
import 'config_screen.dart';

const kBg           = Color(0xFF4D4F66);
const kCard         = Color(0xFF858094);
const kAccentOff    = Color(0xFFC5A0A3);
const kAccentOn     = Color(0xFFF3C9AF);
const kTextPrimary  = Color(0xFFF3C9AF);
const kTextMuted    = Color(0xFFC5A0A3);
const kTextFaint    = Color(0xFF858094);

class HomeScreen extends StatefulWidget {
  final VpnService vpnService;
  const HomeScreen({super.key, required this.vpnService});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnim;
  late final VoidCallback _vpnListener;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.93).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
    _vpnListener = () => setState(() {});
    widget.vpnService.addListener(_vpnListener);
  }

  @override
  void dispose() {
    widget.vpnService.removeListener(_vpnListener);
    _animController.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    _animController.forward().then((_) => _animController.reverse());
    await widget.vpnService.toggle();
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.vpnService;
    final isLoading = svc.status == VpnStatus.connecting;
    final isError = svc.status == VpnStatus.error;
    final color = svc.isConnected
        ? kAccentOn
        : isError
            ? Colors.redAccent
            : kAccentOff;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Row(
          children: [
            const Text('To the Max!',
                style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2)),
            if (Platform.isWindows) ...[
              const SizedBox(width: 8),
              _WindowsBadge(vpnService: svc),
            ],
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: kTextMuted),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConfigScreen(vpnService: svc),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),

            // Статус текст
            Text(
              isLoading
                  ? 'Подключение...'
                  : svc.isConnected
                      ? 'Подключено'
                      : isError
                          ? 'Ошибка'
                          : 'Отключено',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: isLoading ? kTextFaint : color,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              svc.isConnected
                  ? 'Трафик зашифрован'
                  : isError
                      ? 'Смотри логи в настройках'
                      : 'Соединение не защищено',
              style: TextStyle(
                fontSize: 13,
                color: svc.isConnected
                    ? kTextFaint
                    : kAccentOff.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 48),

            // Кнопка
            ScaleTransition(
              scale: _scaleAnim,
              child: GestureDetector(
                onTap: isLoading ? null : _toggle,
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.15),
                    border: Border.all(color: color, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.3),
                        blurRadius: 40,
                        spreadRadius: 10,
                      ),
                    ],
                  ),
                  child: isLoading
                      ? const Center(
                          child: CircularProgressIndicator(color: kTextFaint),
                        )
                      : Icon(
                          svc.isConnected
                              ? Icons.shield
                              : Icons.shield_outlined,
                          size: 72,
                          color: kTextPrimary,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 48),

            // Статистика
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: kCard.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _statItem('Сервер', svc.serverName),
                      _divider(),
                      _statItem('Протокол', svc.protocol),
                      _divider(),
                      _statItem('Пинг', svc.isConnected ? '${svc.ping} ms' : '— ms'),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _statItem('Upload', svc.traffic.uploadBytes),
                      _divider(),
                      _statItem('Download', svc.traffic.downloadBytes),
                      _divider(),
                      _statItem('Speed', _speedLabel(svc)),
                    ],
                  ),
                ],
              ),
            ),

            // Windows: переключатель режима
            if (Platform.isWindows) ...[
              const SizedBox(height: 16),
              _WindowsModeToggle(vpnService: svc),
            ],

            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _statItem(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: kTextFaint)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: kTextPrimary)),
      ],
    );
  }

  Widget _divider() =>
      Container(width: 1, height: 32, color: kTextFaint);

  String _speedLabel(VpnService svc) {
    final upload = svc.traffic.uploadSpeed;
    final download = svc.traffic.downloadSpeed;
    return '↑ $upload / ↓ $download';
  }
}

/// Бейдж платформы в AppBar
class _WindowsBadge extends StatelessWidget {
  final VpnService vpnService;
  const _WindowsBadge({required this.vpnService});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: kTextFaint.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kTextFaint.withValues(alpha: 0.4)),
      ),
      child: Text(
        vpnService.windowsMode == WindowsVpnMode.systemProxy ? 'Proxy' : 'TUN',
        style: const TextStyle(color: kTextFaint, fontSize: 10),
      ),
    );
  }
}

/// Переключатель Proxy ↔ TUN (только Windows)
class _WindowsModeToggle extends StatelessWidget {
  final VpnService vpnService;
  const _WindowsModeToggle({required this.vpnService});

  @override
  Widget build(BuildContext context) {
    final isProxy = vpnService.windowsMode == WindowsVpnMode.systemProxy;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: kCard.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kTextFaint.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isProxy ? 'System Proxy' : 'TUN Tunnel',
                style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
              Text(
                isProxy
                    ? 'Браузер + большинство приложений'
                    : 'Весь трафик ОС (нужны права админа)',
                style: const TextStyle(color: kTextFaint, fontSize: 11),
              ),
            ],
          ),
          Switch(
            value: !isProxy,
            onChanged: vpnService.isConnected
                ? null // нельзя менять в процессе
                : (v) {
                    vpnService.windowsMode = v
                        ? WindowsVpnMode.tunTunnel
                        : WindowsVpnMode.systemProxy;
                  },
            activeThumbColor: kAccentOn,
            activeTrackColor: kAccentOn.withValues(alpha: 0.45),
            inactiveThumbColor: kAccentOff,
            inactiveTrackColor: kTextFaint.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }
}