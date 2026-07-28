import 'package:dartx/dartx.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/overview/offline_servers.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

String _sanitize(String tag) => tag.replaceFirst(RegExp(r"\§[^]*"), "").trimRight();

/// Автопереключение на «резерв» при региональном отключении (whitelist) — «тихо».
///
/// Два случая:
///  1. Туннель НЕ поднимается (висит «Подключение»): стартовый сервер недоступен.
///     Перебираем серверы (обычные → «резерв») переподключением, пока не встанет.
///  2. Туннель поднят (Connected), но интернета нет (все обычные url-test мертвы),
///     а «резерв» жив → уходим на «резерв»; обычные ожили → назад на «Авто».
///
/// «Резерв» помечен §reserve§ (ядро держит его в select, но вне url-test — см.
/// builder.go). Тик вызывается по таймеру (~5с) из App.
///
/// Пинг url-test: 0 = не тестировался/нет ответа, 65535 (большое) = timeout →
/// «мёртв»; «жив» = 0 < пинг < 60000.
class ShutdownFailover with InfraLogger {
  static const _reserveMark = "§reserve§";

  /// Сколько ждать поднятия туннеля, прежде чем перебрать следующий сервер.
  static const _connectTimeoutSec = 18;

  /// Гистерезис для случая «Connected, но интернета нет».
  static const _deadStreakThreshold = 2;

  static bool _dead(int d) => d <= 0 || d >= 60000;
  static bool _alive(int d) => d > 0 && d < 60000;

  DateTime? _connectingSince;
  final Set<String> _tried = {};
  int _deadStreak = 0;
  bool _busy = false;

  Future<void> tick(WidgetRef ref) async {
    if (_busy) return;
    _busy = true;
    try {
      final conn = ref.read(connectionNotifierProvider);
      final status = conn.valueOrNull;

      if (status is Connected) {
        _connectingSince = null;
        _tried.clear();
        await _handleConnectedNoInternet(ref);
        return;
      }

      final failed = conn.hasError || (status is Disconnected && status.connectionFailure != null);
      if (failed) {
        await _tryNextCandidate(ref);
        return;
      }

      if (status is Connecting) {
        _connectingSince ??= DateTime.now();
        if (DateTime.now().difference(_connectingSince!).inSeconds >= _connectTimeoutSec) {
          await _tryNextCandidate(ref);
        }
        return;
      }

      // Disconnected без ошибки (пользователь выключил / простой) — сброс.
      _connectingSince = null;
      _deadStreak = 0;
    } catch (e, s) {
      loggy.warning("shutdown-failover tick error", e, s);
    } finally {
      _busy = false;
    }
  }

  /// Перебор серверов переподключением. Приоритет: обычные, затем «резерв».
  Future<void> _tryNextCandidate(WidgetRef ref) async {
    final names = ref.read(offlineServersProvider).valueOrNull ?? const <String>[];
    if (names.isEmpty) return;

    final ordered = [
      ...names.where((n) => !n.contains(_reserveMark)),
      ...names.where((n) => n.contains(_reserveMark)),
    ];
    final next = ordered.firstOrNullWhere((n) => !_tried.contains(_sanitize(n)));
    if (next == null) {
      // Все перепробованы — реально нет связи. Ждём смены обстановки.
      _connectingSince = null;
      _tried.clear();
      return;
    }

    final display = _sanitize(next);
    _tried.add(display);
    loggy.info("shutdown-failover: туннель не встал → пробуем «$display»");

    final connNotifier = ref.read(connectionNotifierProvider.notifier);
    await connNotifier.abortConnection();
    await Future<void>.delayed(const Duration(seconds: 1));
    // Тот же путь, что ручной выбор сервера в офлайн-списке.
    ref.read(pendingServerSelectionProvider.notifier).state = display;
    await connNotifier.mayConnect();
    _connectingSince = DateTime.now();
  }

  /// Случай 2: Connected, но интернета нет → уходим на «резерв».
  Future<void> _handleConnectedNoInternet(WidgetRef ref) async {
    final group = ref.read(proxiesOverviewNotifierProvider).valueOrNull;
    if (group == null || group.items.isEmpty) {
      _deadStreak = 0;
      return;
    }
    final reserve = group.items.firstOrNullWhere((e) => e.tag.contains(_reserveMark));
    if (reserve == null) {
      _deadStreak = 0;
      return;
    }
    final normals = group.items.where((e) => !e.isGroup && !e.tag.contains(_reserveMark)).toList();
    if (normals.isEmpty) {
      _deadStreak = 0;
      return;
    }
    final lowest = group.items.firstOrNullWhere((e) => e.tagDisplay.trim().toLowerCase() == 'lowest');
    final allNormalsDead = normals.every((e) => _dead(e.urlTestDelay));
    final reserveAlive = _alive(reserve.urlTestDelay);
    final onReserve = group.selected == reserve.tag;
    final notifier = ref.read(proxiesOverviewNotifierProvider.notifier);

    if (!onReserve) {
      if (allNormalsDead && reserveAlive) {
        _deadStreak++;
        if (_deadStreak >= _deadStreakThreshold) {
          loggy.info("shutdown-failover: обычные мертвы, резерв жив → «резерв»");
          await notifier.changeProxy(group.tag, reserve.tag);
          _deadStreak = 0;
        }
      } else {
        _deadStreak = 0;
      }
    } else {
      _deadStreak = 0;
      // Обычные ожили → назад на «Авто» (lowest) или на первый живой обычный.
      final aliveNormal = normals.firstOrNullWhere((e) => _alive(e.urlTestDelay));
      final back = lowest ?? aliveNormal;
      if (back != null && aliveNormal != null) {
        loggy.info("shutdown-failover: обычные ожили → назад на «${back.tagDisplay}»");
        await notifier.changeProxy(group.tag, back.tag);
      }
    }
    await notifier.urlTest(group.tag);
  }
}
