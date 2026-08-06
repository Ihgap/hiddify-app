import 'package:dio/dio.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/custom_loggers.dart';
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

  /// Та же проба, что у failover: доходит ли трафик устройства до интернета
  /// ЧЕРЕЗ туннель. Именно она отличает «стек сломан» от «сервер жив».
  static const _probeUrl = "http://connectivitycheck.gstatic.com/generate_204";

  /// Сколько ждать поднятия туннеля после смены режима.
  static const _connectTimeout = Duration(seconds: 25);

  /// Сколько всего пробовать связь в одном режиме, прежде чем признать неудачу.
  static const _probeWindow = Duration(seconds: 12);

  Future<void> runIfFirstRun() async {
    if (ref.read(Preferences.vpnModePicked)) return;
    if (ref.read(modePickingProvider)) return;

    ref.read(modePickingProvider.notifier).state = true;
    loggy.info("mode picker: starting");
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
        if (await _probeOk()) {
          loggy.info("mode picker: $mode works, remembering");
          await ref.read(Preferences.vpnModePicked.notifier).update(true);
          return;
        }
        loggy.info("mode picker: no traffic in $mode");
      }
      // Ни один режим не дал связи — значит дело не в стеке (сеть, сервер,
      // чужой VPN). Ничего не запоминаем: подбор повторится при следующем
      // включении, когда условия могут быть другими.
      loggy.warning("mode picker: no working mode found, will retry next time");
    } finally {
      ref.read(modePickingProvider.notifier).state = false;
    }
  }

  Future<bool> _waitConnected() async {
    // Сначала дожидаемся, что ядро реально ушло на перезапуск. Сразу после
    // смены настройки статус ещё Connected — не дождавшись разрыва, мы бы
    // измерили пробой СТАРЫЙ стек и запомнили неверный режим.
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

  Future<bool> _probeOk() async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 4),
        validateStatus: (_) => true,
      ),
    );
    final deadline = DateTime.now().add(_probeWindow);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await dio.get<void>(_probeUrl);
        if (r.statusCode == 204 || r.statusCode == 200) return true;
      } catch (_) {
        // нет связи — пробуем ещё, пока не вышло окно
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }
}
