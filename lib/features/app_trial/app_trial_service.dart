import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/app_trial/device_identity.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Ответ бэкенда на POST /app/activate.
class AppTrialResult {
  const AppTrialResult({
    required this.status,
    this.subUrl,
    this.expiresAt,
    this.linked = false,
    this.linkUrl,
    this.payUrl,
    this.routing,
  });

  /// trial_started | active | expired
  final String status;
  final String? subUrl;
  final DateTime? expiresAt;
  final bool linked;
  final String? linkUrl;
  final String? payUrl;

  /// Серверное правило маршрутизации «только зарубежный трафик» (с version).
  final Map<String, dynamic>? routing;

  factory AppTrialResult.fromJson(Map<String, dynamic> j) => AppTrialResult(
    status: (j['status'] as String?) ?? 'unknown',
    subUrl: j['sub_url'] as String?,
    expiresAt: j['expires_at'] != null ? DateTime.tryParse(j['expires_at'] as String) : null,
    linked: (j['linked'] as bool?) ?? false,
    linkUrl: j['link_url'] as String?,
    payUrl: j['pay_url'] as String?,
    routing: (j['routing'] as Map?)?.cast<String, dynamic>(),
  );
}

/// Активация пробного периода на бэкенде бота (тот же сервер, что и Telegram-бот).
///
/// Отдельный Dio: запрос идёт ДО подключения VPN (на первом запуске туннель ещё
/// не поднят), поэтому соединение прямое и не зависит от прокси-логики приложения.
class AppTrialService {
  AppTrialService([Dio? dio])
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 15),
            ),
          );

  final Dio _dio;

  Future<AppTrialResult> activate(String deviceId) async {
    final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();

    var sig = '';
    if (Constants.appHmacSecret.isNotEmpty) {
      final mac = Hmac(sha256, utf8.encode(Constants.appHmacSecret));
      sig = mac.convert(utf8.encode('$deviceId.$ts')).toString();
    }

    // Установки из Google Play не должны видеть кнопки внешней оплаты
    // (Payments policy). Пакет теперь единый для Play и sideload-раздачи,
    // поэтому решает не package, а источник установки: store=play|side.
    // package шлём тоже — как fallback для бэкенда и диагностики.
    final packageName = (await PackageInfo.fromPlatform()).packageName;
    final store = await DeviceIdentity.installedFromPlay() ? 'play' : 'side';

    // Платформа — чтобы бэкенд различал Android/Windows-устройства в статистике.
    // Без этого поля бэкенд определяет платформу по форме device_id, так что
    // старые сборки тоже учитываются; поле лишь делает это однозначным.
    final platform = Platform.isAndroid
        ? 'android'
        : Platform.isWindows
            ? 'windows'
            : Platform.operatingSystem;

    final res = await _dio.post<dynamic>(
      Constants.appActivateUrl,
      data: {
        'device_id': deviceId,
        'ts': ts,
        'sig': sig,
        'package': packageName,
        'store': store,
        'platform': platform,
      },
    );

    final data = res.data;
    if (data is Map) {
      return AppTrialResult.fromJson(data.cast<String, dynamic>());
    }
    if (data is String) {
      return AppTrialResult.fromJson(jsonDecode(data) as Map<String, dynamic>);
    }
    throw const FormatException('unexpected /app/activate response');
  }
}
