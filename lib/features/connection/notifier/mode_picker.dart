import 'package:flutter/services.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Идёт автоподбор рабочего режима. На это время статус показывает «Выбор
/// режима» вместо реального состояния — иначе пользователь видел бы, как
/// туннель несколько раз падает и поднимается.
final modePickingProvider = StateProvider<bool>((ref) => false);

/// Автоподбор рабочего TUN-стека при первом включении.
///
/// Режим — это стек ядра (fast=mixed, compatibility=gvisor, maxSpeed=system), и
/// универсально рабочего среди них нет: на одних устройствах не работает
/// совместимость, на других — быстрый. Человек, у которого при первом запуске
/// «просто не заработало», уходит и считает приложение нерабочим, поэтому
/// подбор идёт молча и без единого вопроса.
///
/// Порядок задан продуктом: сначала быстрый, при неудаче совместимость, затем
/// максимальная скорость.
class ModePicker with InfraLogger {
  ModePicker(this.ref);

  final Ref ref;

  static const _order = [VpnMode.fast, VpnMode.compatibility, VpnMode.maxSpeed];

  /// Тот же канал, что для device_id и состояния экрана.
  static const _channel = MethodChannel('com.ihgap.vpn/device');

  /// Сколько ждать поднятия туннеля после смены режима.
  static const _connectTimeout = Duration(seconds: 25);

  /// Сколько ждать системного вердикта о связности. Флаг выставляется не сразу:
  /// системе нужно несколько секунд на собственную пробу после подъёма сети.
  static const _validateTimeout = Duration(seconds: 20);

  Future<void> runIfFirstRun() async {
    // Проблема разных стеков — андроидная; на десктопе режим не перебираем.
    if (!PlatformUtils.isAndroid) return;
    if (ref.read(Preferences.vpnModePicked)) return;
    if (ref.read(modePickingProvider)) return;

    final original = ref.read(ConfigOptions.vpnMode);
    ref.read(modePickingProvider.notifier).state = true;
    loggy.info("mode picker: starting from $original");
    try {
      for (final mode in _order) {
        if (ref.read(ConfigOptions.vpnMode) != mode) {
          loggy.info("mode picker: trying $mode");
          await ref.read(ConfigOptions.vpnMode.notifier).update(mode);
          // Смена режима поднимает requiresReconnect, и ConnectionWrapper
          // переподключает ядро сам — здесь только ждём результата.
          if (!await _waitConnected()) {
            loggy.info("mode picker: $mode did not come up");
            continue;
          }
        }
        if (await _tunnelValidated()) {
          loggy.info("mode picker: $mode works, remembering");
          await ref.read(Preferences.vpnModePicked.notifier).update(true);
          return;
        }
        loggy.info("mode picker: no traffic through tunnel in $mode");
      }

      // Ни один режим не прошёл проверку. Причина может быть вовсе не в стеке
      // (нет сети, лежит сервер, занят чужой VPN, ROM не проверяет VPN-сети),
      // поэтому выбор НЕ фиксируем и возвращаем режим, который стоял до нас:
      // иначе пользователь остался бы на последнем перебранном варианте, а это
      // хуже дефолта. Подбор повторится при следующем включении.
      loggy.warning("mode picker: no working mode found, restoring $original");
      if (ref.read(ConfigOptions.vpnMode) != original) {
        await ref.read(ConfigOptions.vpnMode.notifier).update(original);
      }
    } finally {
      ref.read(modePickingProvider.notifier).state = false;
    }
  }

  Future<bool> _waitConnected() async {
    // Сначала дожидаемся, что ядро реально ушло на перезапуск. Сразу после
    // смены настройки статус ещё Connected — не дождавшись разрыва, мы бы
    // проверили СТАРЫЙ стек и запомнили неверный режим.
    final leaveDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(leaveDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (ref.read(connectionNotifierProvider).valueOrNull is! Connected) break;
    }

    final deadline = DateTime.now().add(_connectTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (ref.read(connectionNotifierProvider).valueOrNull is Connected) return true;
    }
    return false;
  }

  /// Система подтвердила, что через VPN-сеть ходит трафик.
  ///
  /// Свою пробу из приложения делать бесполезно: приложение исключено из
  /// собственного туннеля (VPNService.openTun), поэтому его запросы уходят
  /// напрямую и отвечают даже при наглухо сломанном стеке.
  Future<bool> _tunnelValidated() async {
    final deadline = DateTime.now().add(_validateTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        if (await _channel.invokeMethod<bool>('isVpnValidated') ?? false) return true;
      } catch (e) {
        loggy.warning("mode picker: validation check failed: $e");
        return false;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return false;
  }
}
