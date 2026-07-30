import 'package:dartx/dartx.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/overview/offline_servers.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
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
/// builder.go). Тик вызывается по таймеру (~8с) из App; при погашенном экране
/// работа прореживается до раза в ~60с и активная проба не выполняется.
///
/// Пинг url-test: 0 = не тестировался/нет ответа, 65535 (большое) = timeout →
/// «мёртв»; «жив» = 0 < пинг < 60000.
class ShutdownFailover with InfraLogger {
  static const _reserveMark = "§reserve§";

  /// Сколько ждать поднятия туннеля, прежде чем перебрать следующий сервер.
  static const _connectTimeoutSec = 12;

  /// Гистерезис для случая «Connected, но интернета нет».
  static const _deadStreakThreshold = 2;

  /// Сколько разных обычных серверов подряд должны не встать, чтобы сразу
  /// прыгнуть на резерв, не досматривая остаток списка (много падений = зона).
  static const _normalsFailForReserve = 2;

  /// Активная проба связи через туннель: URL, частота, порог провалов.
  /// Проба идёт ЧЕРЕЗ активный (обычный) сервер за границей — если туннель жив,
  /// generate_204 доступен; в зоне белых списков туннель мёртв → проба падает.
  /// Проба выполняется, только когда пользователь реально смотрит на телефон:
  /// приложение на переднем плане ИЛИ экран устройства включён (Android,
  /// см. _screenOn). При погашенном экране HTTP-запрос каждые 8с не давал
  /// сотовому модему уснуть (после каждой передачи радио ~5-10с держится в
  /// активном состоянии) — главный источник фонового расхода батареи. При
  /// включённом экране радио и так активно, а детект остаётся быстрым (~20с).
  static const _probeUrl = "http://connectivitycheck.gstatic.com/generate_204";
  static const _probeEverySec = 8;
  static const _probeFailForDown = 2;

  /// В фоне тик прореживается до раза в [_bgTickEverySec] (таймер в App
  /// продолжает дёргать каждые ~8с, но работа выполняется реже). Детект в фоне
  /// остаётся — по пассивным url-test-данным ядра, без активной пробы.
  static const _bgTickEverySec = 60;

  static bool _dead(int d) => d <= 0 || d >= 60000;
  static bool _alive(int d) => d > 0 && d < 60000;

  /// null на старте (до первого lifecycle-события) считаем передним планом.
  static bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Тот же канал, что для device_id (MainActivity). Binder-вызов внутри
  /// устройства — копеечный, радио не трогает.
  static const _deviceChannel = MethodChannel('com.ihgap.vpn/device');

  /// Включён ли экран устройства. Только Android; при любой ошибке канала —
  /// консервативно false (нет пробы).
  static Future<bool> _screenOn() async {
    if (!PlatformUtils.isAndroid) return false;
    try {
      return await _deviceChannel.invokeMethod<bool>('isScreenOn') ?? false;
    } catch (_) {
      return false;
    }
  }

  DateTime? _connectingSince;
  final Set<String> _tried = {};
  int _deadStreak = 0;
  DateTime? _lastForcedTest;
  DateTime? _lastProbe;
  int _probeFailStreak = 0;
  bool _busy = false;
  DateTime? _lastBgTick;
  bool _probeAllowed = true;

  Future<void> tick(WidgetRef ref) async {
    if (_busy) return;
    _busy = true;
    try {
      // «Активный» = пользователь смотрит на телефон: приложение открыто ИЛИ
      // включён экран. Определяет и частоту работы, и право на активную пробу.
      final active = _foreground || await _screenOn();
      _probeAllowed = active;
      if (!active) {
        final now = DateTime.now();
        if (_lastBgTick != null && now.difference(_lastBgTick!).inSeconds < _bgTickEverySec) {
          return;
        }
        _lastBgTick = now;
      }
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
    final reserveName = ordered.firstOrNullWhere((n) => n.contains(_reserveMark));
    final reserveTried = reserveName != null && _tried.contains(_sanitize(reserveName));
    // Если несколько разных обычных подряд не встали — это зона, а не сбой
    // одного сервера: сразу прыгаем на резерв, не перебирая остаток списка.
    final String? next;
    if (_tried.length >= _normalsFailForReserve && reserveName != null && !reserveTried) {
      next = reserveName;
    } else {
      next = ordered.firstOrNullWhere((n) => !_tried.contains(_sanitize(n)));
    }
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
      // Быстрый путь: активная HTTP-проба через текущий (обычный) сервер.
      // Два провала подряд (~16с) = трафик реально не идёт → сразу на резерв.
      // Только при включённом экране/открытом приложении: с погашенным экраном
      // пробу не делаем (батарея), детект работает по запасному пути ниже
      // (url-test-данные ядра).
      final probeDown = _probeAllowed && await _probeConnectivity();
      if (probeDown && reserveAlive) {
        loggy.info("shutdown-failover: проба связи не прошла, резерв жив → «резерв»");
        await notifier.changeProxy(group.tag, reserve.tag);
        _deadStreak = 0;
        _probeFailStreak = 0;
      } else if (allNormalsDead && reserveAlive) {
        // Запасной путь по url-test (медленнее пробы) с гистерезисом.
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
    // Свежий url-test форсим ТОЛЬКО при подозрении на обрыв (не на резерве и
    // хотя бы один обычный не отвечает) и не чаще раза в 15с. Безусловный
    // форс каждый тик заставлял url-test-группу «Авто» переизбирать лучший
    // сервер каждые 5с → видимые перескоки. При штатной работе (все живы)
    // форса нет; периодический автотест группы делает само ядро.
    if (!onReserve && reserveAlive && normals.any((e) => _dead(e.urlTestDelay))) {
      final now = DateTime.now();
      if (_lastForcedTest == null || now.difference(_lastForcedTest!).inSeconds >= 15) {
        _lastForcedTest = now;
        await notifier.urlTest(group.tag);
      }
    }
  }

  /// Активная проба связи через активный туннель. true = связь подтверждённо
  /// не работает (>= _probeFailForDown провалов подряд). Троттл _probeEverySec —
  /// между пробами отдаёт последний вердикт (тик чаще пробы). Запрос идёт через
  /// системный стек → активный TUN → текущий сервер: в зоне белых списков он
  /// не доходит до generate_204 и падает по таймауту.
  Future<bool> _probeConnectivity() async {
    final now = DateTime.now();
    if (_lastProbe != null && now.difference(_lastProbe!).inSeconds < _probeEverySec) {
      return _probeFailStreak >= _probeFailForDown;
    }
    _lastProbe = now;
    bool ok;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        validateStatus: (s) => s != null && s < 500,
      ));
      final r = await dio.get(_probeUrl);
      ok = r.statusCode != null && r.statusCode! < 400;
    } catch (_) {
      ok = false;
    }
    _probeFailStreak = ok ? 0 : _probeFailStreak + 1;
    return _probeFailStreak >= _probeFailForDown;
  }
}
