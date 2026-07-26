import 'dart:io';

import 'package:flutter/services.dart';

/// Устойчивый идентификатор устройства для анти-абуза пробного периода.
///
/// Android: `Settings.Secure.ANDROID_ID` через нативный канал (см. MainActivity.kt).
/// ANDROID_ID переживает переустановку приложения и очистку данных, привязан к
/// ключу подписи + пакету — стабилен именно для нашего APK. Меняется только при
/// сбросе устройства к заводским настройкам (осознанно принятая дыра).
///
/// Windows: `MachineGuid` из HKLM\SOFTWARE\Microsoft\Cryptography — генерируется
/// при установке ОС, переживает переустановку приложения. Меняется только при
/// переустановке Windows (та же осознанная дыра, что и factory reset).
class DeviceIdentity {
  static const _channel = MethodChannel('com.ihgap.vpn/device');

  /// Возвращает стабильный идентификатор устройства текущей платформы,
  /// либо null если платформа не поддержана / идентификатор недоступен.
  static Future<String?> deviceId() async {
    if (Platform.isAndroid) return _androidId();
    if (Platform.isWindows) return _windowsMachineGuid();
    return null;
  }

  static Future<String?> _androidId() async {
    try {
      final id = await _channel.invokeMethod<String>('getAndroidId');
      if (id == null || id.isEmpty) return null;
      return id;
    } catch (_) {
      return null;
    }
  }

  static final _guidRe = RegExp(
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
  );

  static Future<String?> _windowsMachineGuid() async {
    try {
      final result = await Process.run('reg', [
        'query',
        r'HKLM\SOFTWARE\Microsoft\Cryptography',
        '/v',
        'MachineGuid',
      ]);
      if (result.exitCode != 0) return null;
      return _guidRe.firstMatch(result.stdout.toString())?.group(0);
    } catch (_) {
      return null;
    }
  }
}
