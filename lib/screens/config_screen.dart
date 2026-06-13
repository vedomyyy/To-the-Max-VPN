import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/vpn_service.dart';

const kBg          = Color(0xFF4D4F66);
const kCard        = Color(0xFF858094);
const kAccentOn    = Color(0xFFF3C9AF);
const kTextPrimary = Color(0xFFF3C9AF);
const kTextMuted   = Color(0xFFC5A0A3);
const kTextFaint   = Color(0xFF858094);

class ConfigScreen extends StatefulWidget {
  final VpnService vpnService;
  const ConfigScreen({super.key, required this.vpnService});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.vpnService.config);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    // Определяем тип защиты для сообщения пользователю
    String securityLabel = '';
    String? warningMessage;
    try {
      final uri = Uri.parse(text);
      final q = uri.queryParameters;
      final security = q['security'] ?? 'none';
      final scheme = uri.scheme.toUpperCase();
      securityLabel = switch (security) {
        'reality' => '$scheme + Reality',
        'tls'     => '$scheme + TLS',
        'none'    => '$scheme (без шифрования)',
        _         => '$scheme ($security)',
      };
      // Предупреждаем если Reality URL неполный
      if (security == 'reality') {
        final missing = <String>[];
        if ((q['pbk'] ?? '').isEmpty) missing.add('pbk');
        if ((q['sid'] ?? '').isEmpty) missing.add('sid');
        if ((q['sni'] ?? '').isEmpty) missing.add('sni');
        if (missing.isNotEmpty) {
          warningMessage = '⚠ Reality: отсутствуют параметры: ${missing.join(', ')}';
        }
      }
    } catch (_) {}

    widget.vpnService.setConfig(text);

    if (warningMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(warningMessage!),
          backgroundColor: Colors.orange.shade900,
          duration: const Duration(seconds: 4),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            securityLabel.isEmpty ? 'Конфиг сохранён' : 'Сохранено: $securityLabel',
          ),
          backgroundColor: const Color(0xFF1A1A2E),
        ),
      );
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: const Text('Настройки',
            style: TextStyle(color: kTextPrimary, fontSize: 18)),
        iconTheme: const IconThemeData(color: kTextPrimary),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Вставьте пригласительную ссылку',
                style: TextStyle(color: kTextMuted, fontSize: 13)),
            const SizedBox(height: 8),
            const Text('vless://... или vmess://...',
                style: TextStyle(color: kTextFaint, fontSize: 11)),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: kCard.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kTextFaint.withOpacity(0.3)),
              ),
              child: TextField(
                controller: _controller,
                maxLines: 4,
                style: const TextStyle(
                    color: kTextPrimary, fontSize: 13, height: 1.5),
                decoration: const InputDecoration(
                  hintText: 'vless://...',
                  hintStyle: TextStyle(color: kTextFaint),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(16),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccentOn.withOpacity(0.2),
                  foregroundColor: kTextPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: kAccentOn.withOpacity(0.5)),
                  ),
                ),
                child: const Text('Сохранить',
                    style: TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Логи',
                    style: TextStyle(color: kTextMuted, fontSize: 13)),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(
                        text: widget.vpnService.logs.join('\n')));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Логи скопированы'),
                        backgroundColor: Color(0xFF1A1A2E),
                      ),
                    );
                  },
                  child: const Text('Копировать',
                      style: TextStyle(color: kTextFaint, fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kTextFaint.withOpacity(0.2)),
                ),
                child: ListenableBuilder(
                  listenable: widget.vpnService,
                  builder: (context, _) {
                    final logs = widget.vpnService.logs;
                    return ListView.builder(
                      itemCount: logs.length,
                      itemBuilder: (context, index) {
                        final log = logs[index];
                        Color logColor = kTextFaint;
                        if (log.contains('ERROR') || log.contains('error')) {
                          logColor = Colors.redAccent;
                        } else if (log.contains('CONNECTED') ||
                            log.contains('connected')) {
                          logColor = Colors.greenAccent;
                        } else if (log.contains('WARNING') ||
                            log.contains('warning')) {
                          logColor = Colors.orangeAccent;
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            log,
                            style: TextStyle(
                              color: logColor,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}