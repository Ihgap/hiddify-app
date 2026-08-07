import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
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
/// Режим считается рабочим по двум проверкам: системная валидация туннеля
/// (трафик вообще ходит) и проба Телеграма через туннель. Вторая нужна из-за
/// реального кейса: в mixed-стеке TCP идёт через ядро, и на части прошивок
/// маленькая системная проба проходит, а крупные пакеты теряются — Телеграм
/// (чистый TCP без QUIC-фолбэка) не грузится, хотя валидация зелёная.
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

  /// Таймаут одной TLS-пробы (TCP-коннект + рукопожатие).
  static const _probeTimeout = Duration(seconds: 10);

  Future<void> runIfFirstRun() async {
    // Проблема разных стеков — андроидная; на десктопе режим не перебираем.
    if (!PlatformUtils.isAndroid) return;

    // Страховка: если прошлый подбор оборвался (смерть процесса), флаг
    // прощупывания мог остаться поднятым — тогда каждый следующий туннель
    // строился бы без исключения приложения. Гасим до любых ранних выходов;
    // текущий туннель не трогаем, обычный вид вернётся ближайшим реконнектом.
    if (ref.read(Preferences.vpnModeProbing)) {
      loggy.warning("mode picker: stale probing flag found, clearing");
      await ref.read(Preferences.vpnModeProbing.notifier).update(false);
    }

    if (ref.read(Preferences.vpnModePicked)) return;
    if (ref.read(modePickingProvider)) return;

    final original = ref.read(ConfigOptions.vpnMode);
    ref.read(modePickingProvider.notifier).state = true;
    loggy.info("mode picker: starting from $original");

    // Режим, где трафик ходит (валидация + контрольная проба), но Телеграм
    // не открылся. Пригодится, если Телеграм не откроется нигде.
    VpnMode? fallback;
    try {
      await ref.read(Preferences.vpnModeProbing.notifier).update(true);
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
        } else {
          // Режим уже активен, но туннель поднимался ДО флага прощупывания —
          // приложение исключено, и пробы ушли бы мимо туннеля. Переоткрываем.
          loggy.info("mode picker: reopening tunnel to probe $mode");
          if (!await _reconnectAndWait()) {
            loggy.info("mode picker: $mode did not come back up");
            continue;
          }
        }
        if (!await _tunnelValidated()) {
          loggy.info("mode picker: no traffic through tunnel in $mode");
          continue;
        }
        if (await _telegramReachable()) {
          loggy.info("mode picker: $mode works, remembering");
          await ref.read(Preferences.vpnModePicked.notifier).update(true);
          return;
        }
        loggy.info("mode picker: $mode carries traffic, but telegram is unreachable");
        if (fallback == null && await _controlReachable()) fallback = mode;
      }

      if (fallback != null) {
        // Телеграм не открылся ни в одном режиме при живом остальном трафике —
        // значит, дело не в стеке (лежит сам Телеграм или его IP прижали на
        // нашем сервере). Берём первый режим, где трафик ходил: браковать
        // исправные режимы из-за чужой аварии нельзя.
        loggy.warning("mode picker: telegram unreachable everywhere, settling for $fallback");
        if (ref.read(ConfigOptions.vpnMode) != fallback) {
          await ref.read(ConfigOptions.vpnMode.notifier).update(fallback);
          await _waitConnected();
        }
        await ref.read(Preferences.vpnModePicked.notifier).update(true);
        return;
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
      await ref.read(Preferences.vpnModeProbing.notifier).update(false);
      // Вернуть туннель к обычному виду: приложение снова вне туннеля.
      await _restoreSelfExclusion();
      ref.read(modePickingProvider.notifier).state = false;
    }
  }

  Future<bool> _waitConnected({bool awaitDisconnect = true}) async {
    if (awaitDisconnect) {
      // Сначала дожидаемся, что ядро реально ушло на перезапуск. Сразу после
      // смены настройки статус ещё Connected — не дождавшись разрыва, мы бы
      // проверили СТАРЫЙ стек и запомнили неверный режим.
      final leaveDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(leaveDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (ref.read(connectionNotifierProvider).valueOrNull is! Connected) break;
      }
    }

    final deadline = DateTime.now().add(_connectTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (ref.read(connectionNotifierProvider).valueOrNull is Connected) return true;
    }
    return false;
  }

  /// Переподключение без смены настроек — чтобы туннель переоткрылся уже с
  /// флагом прощупывания. reconnect() сам дожидается рестарта ядра, поэтому
  /// фазу «ждём разрыва» в _waitConnected пропускаем.
  Future<bool> _reconnectAndWait() async {
    try {
      await ref
          .read(connectionNotifierProvider.notifier)
          .reconnect(await ref.read(activeProfileProvider.future));
    } catch (e) {
      loggy.warning("mode picker: reconnect failed: $e");
      return false;
    }
    return _waitConnected(awaitDisconnect: false);
  }

  /// После подбора туннель поднят без исключения приложения — переоткрываем
  /// его в обычном виде. Если туннель к этому моменту не работает, ничего не
  /// делаем: следующий connect и так прочитает уже снятый флаг.
  Future<void> _restoreSelfExclusion() async {
    try {
      if (ref.read(connectionNotifierProvider).valueOrNull is! Connected) return;
      await ref
          .read(connectionNotifierProvider.notifier)
          .reconnect(await ref.read(activeProfileProvider.future));
    } catch (e) {
      loggy.warning("mode picker: failed to restore self-exclusion: $e");
    }
  }

  /// Система подтвердила, что через VPN-сеть ходит трафик.
  ///
  /// Проба системы маленькая (сотни байт), поэтому ловит только полностью
  /// мёртвый стек. Случай «мелкие пакеты ходят, крупные теряются» ловят уже
  /// TLS-пробы ниже.
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

  /// Телеграм доступен через туннель. Пробуем два независимых хоста — чтобы
  /// разовая недоступность одного не забраковала исправный режим.
  Future<bool> _telegramReachable() async {
    final results = await Future.wait([
      _tlsHandshakeOk("api.telegram.org"),
      _tlsHandshakeOk("web.telegram.org"),
    ]);
    return results.contains(true);
  }

  /// Контрольная проба не-Телеграма: отличает «сломан только Телеграм» от
  /// «через туннель вообще ничего не ходит».
  Future<bool> _controlReachable() => _tlsHandshakeOk("www.gstatic.com");

  /// TLS-рукопожатие как проба транспорта: сервер присылает цепочку
  /// сертификатов — несколько килобайт полноразмерными пакетами, поэтому
  /// проба ловит и «TCP не ходит вообще», и «режутся крупные пакеты» (MTU).
  /// Валидность сертификата не важна — проверяем транспорт, а не подлинность.
  ///
  /// Работает только пока приложение внутри туннеля (флаг прощупывания):
  /// в обычной жизни запрос ушёл бы напрямую и «успех» ничего бы не значил.
  Future<bool> _tlsHandshakeOk(String host) async {
    SecureSocket? socket;
    try {
      socket = await SecureSocket.connect(
        host,
        443,
        timeout: _probeTimeout,
        onBadCertificate: (_) => true,
      ).timeout(_probeTimeout);
      return true;
    } catch (e) {
      loggy.debug("mode picker: tls probe to $host failed: $e");
      return false;
    } finally {
      socket?.destroy();
    }
  }
}
