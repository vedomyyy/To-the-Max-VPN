import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart'; 
 

import 'screens/home_screen.dart';
import 'services/vpn_service.dart';
import 'services/tray_service.dart';

// 1. Добавляем List<String> args в аргументы функции main
void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Проверяем, запущено ли уже приложение (только для Windows)
  if (Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      args, // 2. Передаем аргументы запуска вместо пустого массива
      "to_the_max_vpn_app", 
      // 3. ИСПРАВЛЕНО: правильное имя параметра для этого пакета
      onSecondWindow: (arguments) async {
        // Этот код выполнится в ПЕРВОМ процессе при повторном клике на ярлык
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  // Инициализируем window_manager до всего остального (только Windows)
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true); // закрытие → сворачивание в трей
    await windowManager.setTitle('To the Max!');
    await windowManager.setMinimumSize(const Size(420, 720));
    await windowManager.setSize(const Size(420, 720));
    await windowManager.center();
  }

  final vpnService = VpnService();
  await vpnService.initialize();

  runApp(VpnApp(vpnService: vpnService));
}



// Класс VpnApp и его State остаются АБСОЛЮТНО БЕЗ ИЗМЕНЕНИЙ...
class VpnApp extends StatefulWidget {
  final VpnService vpnService;
  const VpnApp({super.key, required this.vpnService});

  @override
  State<VpnApp> createState() => _VpnAppState();
}

class _VpnAppState extends State<VpnApp> with WindowListener {
  late TrayService _tray;

  @override
  void initState() {
    super.initState();

    if (Platform.isWindows) {
      windowManager.addListener(this);

      _tray = TrayService(
        vpn: widget.vpnService,
        onShowWindow: _showWindow,
        onExit: _exitApp,
      );
      _tray.initialize();
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      _tray.dispose();
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  void _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void _exitApp() async {
    if (widget.vpnService.isConnected) {
      await widget.vpnService.toggle();
    }
    await _tray.dispose();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'To the Max!',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF4D4F66),
      ),
      home: HomeScreen(vpnService: widget.vpnService),
    );
  }
}
