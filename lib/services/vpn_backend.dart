import 'dart:async';

/// Абстрактный интерфейс для платформенных бэкендов VPN.
/// Android реализует через flutter_v2ray, Windows — через xray.exe + системный прокси.
abstract class VpnBackend {
  /// Поток событий статуса. Бэкенд пушит [BackendStatus] при любом изменении.
  Stream<BackendStatus> get statusStream;

  /// Поток логов (одна строка на событие, без временной метки — VpnService добавит).
  Stream<String> get logStream;

  /// Инициализация (запрос разрешений, проверка бинарей и т.д.).
  Future<void> initialize();

  /// Парсим VPN-ссылку и сохраняем параметры подключения.
  /// Бросает [VpnConfigException] если формат не поддерживается.
  Future<void> setConfig(String url);

  /// Возвращает текущий human-readable конфиг (исходная ссылка).
  String get configUrl;

  /// Пинг до сервера в мс, 0 если нет данных.
  Future<int> measurePing();

  /// Запускает VPN-туннель. Статус придёт через [statusStream].
  Future<void> connect();

  /// Останавливает VPN-туннель.
  Future<void> disconnect();

  /// Освобождает ресурсы.
  Future<void> dispose();
}

enum BackendStatus {
  disconnected,
  connecting,
  connected,
  error,
}

class VpnConfigException implements Exception {
  final String message;
  VpnConfigException(this.message);

  @override
  String toString() => 'VpnConfigException: $message';
}