import 'package:flutter/services.dart';

/// Устойчивый идентификатор устройства для анти-абуза пробного периода.
///
/// Читает `Settings.Secure.ANDROID_ID` через нативный канал (см. MainActivity.kt).
/// ANDROID_ID переживает переустановку приложения и очистку данных, привязан к
/// ключу подписи + пакету — стабилен именно для нашего APK. Меняется только при
/// сбросе устройства к заводским настройкам (осознанно принятая дыра).
class DeviceIdentity {
  static const _channel = MethodChannel('com.ihgap.vpn/device');

  /// Возвращает ANDROID_ID, либо null если платформа не Android / канал недоступен.
  static Future<String?> androidId() async {
    try {
      final id = await _channel.invokeMethod<String>('getAndroidId');
      if (id == null || id.isEmpty) return null;
      return id;
    } catch (_) {
      return null;
    }
  }
}
