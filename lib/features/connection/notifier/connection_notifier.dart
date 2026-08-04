import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/utils/windows_privileges.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profiles_update_notifier.dart';
import 'package:path/path.dart' as p;
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

part 'connection_notifier.g.dart';

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  /// true только если пользователь явно нажал «Подключить» в этой сессии.
  /// Сбрасывается при Disconnected, чтобы не стрелять haptic при открытии
  /// приложения с уже работающим VPN (поток проходит Connecting→Connected
  /// без действия пользователя).
  bool _userInitiatedConnect = false;

  /// true пока ждём, что нативный стрим подтвердит Connecting/Connected после
  /// того, как пользователь нажал «Подключить». Подавляет транзиентный
  /// Disconnected, который ядро может выдать при рестарте (особенно из паузы).
  bool _awaitingConnect = false;

  @override
  Stream<ConnectionStatus> build() async* {
    _userInitiatedConnect = false;
    _awaitingConnect = false;

    if (Platform.isIOS) {
      await _connectionRepo.setup().mapLeft((l) {
        loggy.error("error setting up connection repository", l);
      }).run();
    }

    listenSelf((previous, next) async {
      if (previous == next) return;

      if (next case AsyncData(value: final Disconnected _)) {
        _userInitiatedConnect = false;
      }

      if (next case AsyncData(value: final Connected _)) {
        // Появился туннель — прогоняем просроченные обновления подписки прямо
        // сейчас. Смысл в блокировках: если домен подписки режут, обновления
        // снаружи падают, но изнутри туннеля проходят. Без этого приложение
        // всё равно починилось бы само, но только на очередном 15-минутном
        // цикле планировщика. Намеренно не форсируем — профили с неистёкшим
        // интервалом не трогаются, лишней нагрузки нет.
        // Вне ветки _userInitiatedConnect: автоподключение при старте лечить
        // нужно ровно так же, как ручное.
        unawaited(
          ref.read(foregroundProfilesUpdateNotifierProvider.notifier).triggerIfDue(),
        );

        if (_userInitiatedConnect) {
          _userInitiatedConnect = false;
          await ref.read(hapticServiceProvider.notifier).heavyImpact();

          if (Platform.isAndroid && !ref.read(Preferences.storeReviewedByUser)) {
            if (await InAppReview.instance.isAvailable()) {
              InAppReview.instance.requestReview();
              ref.read(Preferences.storeReviewedByUser.notifier).update(true);
            }
          }
        }
      }
    });

    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) async {
      if (previous == null) return;
      final shouldReconnect = next == null || previous.id != next.id;
      if (shouldReconnect) {
        await reconnect(next);
      }
    });
    ref.watch(coreRestartSignalProvider);

    yield* _connectionRepo.watchConnectionStatus().map((event) {
      if (_awaitingConnect) {
        if (event is Connecting || event is Connected) {
          _awaitingConnect = false;
        } else if (event is Disconnected && event.connectionFailure != null) {
          _awaitingConnect = false;
        } else if (event is Disconnected) {
          loggy.debug("suppressing transient Disconnected after user-initiated connect");
          return const Connecting();
        }
      }
      return event;
    }).doOnData((event) {
      if (event case Disconnected(connectionFailure: final _?) when PlatformUtils.isDesktop) {
        Future.microtask(() => ref.read(Preferences.startedByUser.notifier).update(false));
      }
      loggy.info("connection status: ${event.format()}");
    });
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  Future<void> mayConnect() async {
    if (state case AsyncData(:final value)) {
      if (value case Disconnected()) return _connect();
    }
  }

  /// Подключение автоматическое (настройка «Запускать туннель при запуске»),
  /// а не по кнопке. Гасит модальные диалоги: при автозапуске с тихим стартом
  /// приложение сидит в трее, и всплывающее окно там неуместно.
  bool _autoConnecting = false;

  /// Автоподключение при запуске приложения. Срабатывает один раз за запуск
  /// процесса — возврат из фона сюда не попадает, там своя логика
  /// ([reconnectIfDroppedInBackground]).
  Future<void> connectOnAppStart() async {
    if (!ref.read(Preferences.connectOnStart)) return;

    // Ядро инициализируется асинхронно, и до первого статуса состояние — просто
    // «неизвестно». Дёргать connect вслепую нельзя: на Android туннель может
    // уже работать (процесс UI умирал, сервис жил), и мы бы его перезапустили.
    final status = await _awaitResolvedStatus(const Duration(seconds: 15));
    if (status is! Disconnected) {
      loggy.info("connect on start: status is ${status?.format() ?? 'unknown'}, skipping");
      return;
    }
    if (await ref.read(activeProfileProvider.future) == null) {
      loggy.info("connect on start: no active profile, skipping");
      return;
    }

    loggy.info("connect on start: connecting");
    _autoConnecting = true;
    _awaitingConnect = true;
    state = const AsyncData(Connecting());
    await ref.read(Preferences.startedByUser.notifier).update(true);
    try {
      await _connect();
    } finally {
      _autoConnecting = false;
    }
  }

  Future<ConnectionStatus?> _awaitResolvedStatus(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final value = state.valueOrNull;
      if (value != null) return value;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return null;
  }

  /// Быстрое восстановление при возврате в приложение: если пользователь включал
  /// VPN, а он упал в фоне (Doze/сон/простой), сразу переподключаемся — мгновеннее
  /// таймера failover и почти бесплатно по батарее (экран уже активен, Doze снят).
  /// Вызывается из App.onResume. startedByUser=false, когда пользователь сам
  /// выключил VPN, поэтому «тихий» сброс мы не трогаем.
  Future<void> reconnectIfDroppedInBackground() async {
    if (!ref.read(Preferences.startedByUser)) return;
    final value = state.valueOrNull;
    if (value is Connected || value is Connecting) return; // работает / уже поднимается
    // Стрим статуса при возврате в приложение переустанавливается и до первого
    // события отдаёт либо ничего, либо устаревший Disconnected. Верить ему здесь
    // нельзя: реконнект начинается с остановки сервиса, то есть мы бы своими
    // руками рвали живой туннель. Спрашиваем ядро напрямую.
    final actual = await _connectionRepo.probeConnectionStatus();
    if (actual is Connected || actual is Connecting) {
      loggy.info("resume: core is alive, status stream is just catching up");
      if (state.valueOrNull != actual) state = AsyncData(actual!);
      return;
    }
    loggy.info("resume: VPN was on but dropped in background → reconnecting");
    await _connect();
  }

  Future<void> toggleConnection() async {
    final haptic = ref.read(hapticServiceProvider.notifier);
    if (state case AsyncError()) {
      await haptic.lightImpact();
      await _connect();
    } else if (state case AsyncData(:final value)) {
      switch (value) {
        case Disconnected():
          _userInitiatedConnect = true;
          _awaitingConnect = true;
          _deletePausedMarker();
          await haptic.lightImpact();
          state = const AsyncData(Connecting());
          await ref.read(Preferences.startedByUser.notifier).update(true);
          await _connect();
        case Connected():
          // default:
          await haptic.mediumImpact();
          await ref.read(Preferences.startedByUser.notifier).update(false);
          await _disconnect();
        default:
          loggy.warning("switching status, debounce");
      }
    }
  }

  Future<void> reconnect(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        return _disconnect();
      }
      loggy.info("active profile changed, reconnecting");
      await ref.read(Preferences.startedByUser.notifier).update(true);
      await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).mapLeft((err) async {
        loggy.warning("error reconnecting", err);
        state = AsyncError(err, StackTrace.current);
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      }).run();
    }
  }

  Future<void> abortConnection() async {
    if (state case AsyncData(:final value)) {
      switch (value) {
        case Connected() || Connecting():
          loggy.debug("aborting connection");
          await _disconnect();
        default:
      }
    }
  }

  final _singleStart = SingleCall();

  Future<void> _connect() async {
    _singleStart.run(
      () async {
        await _connectThrottled();
      },
      onIgnored: () {
        loggy.debug("connect called while another connect/disconnect is still running, ignoring");
      },
    );
  }

  Future<void> _connectThrottled() async {
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("no active profile, not connecting");
      return;
    }
    await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).mapLeft((
      ConnectionFailure err,
    ) async {
      loggy.warning("error connecting", err);
      //Go err is not normal object to see the go errors are string and need to be dumped
      if (_autoConnecting) {
        // Автоподключение молчит: иначе при автозапуске с тихим стартом
        // пользователь получал бы модальное окно (а в VPN-режиме без прав —
        // ещё и UAC) на каждый вход в систему. Причина остаётся в логах, а
        // кнопка подключения покажет диалог, если нажать её руками.
        loggy.info("auto connect failed, not showing dialog: $err");
      } else if (err is MissingPrivilege) {
        // Тупик без выхода: обычный диалог сообщил бы «нужны права админа» и
        // оставил пользователя один на один с этим. Предлагаем перезапуск.
        await _offerRelaunchAsAdmin();
      } else {
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      }
      loggy.warning(err);
      if (err.toString().contains("panic")) {
        await Sentry.captureException(Exception(err.toString()));
      }
      await ref.read(Preferences.startedByUser.notifier).update(false);
      state = AsyncError(err, StackTrace.current);
    }).run();
  }

  /// Режим «VPN» на Windows требует прав администратора. Показываем причину и
  /// сразу даём выход — перезапуск через UAC, а не «разбирайся сам».
  Future<void> _offerRelaunchAsAdmin() async {
    final t = ref.read(translationsProvider).requireValue;
    final confirmed = await ref
        .read(dialogNotifierProvider.notifier)
        .showConfirmation(
          title: t.errors.singbox.missingPrivilege,
          message: t.errors.singbox.missingPrivilegeMsg,
          positiveBtnTxt: "Перезапустить от имени администратора",
        );
    if (!confirmed) return;
    if (!relaunchAsAdmin()) {
      loggy.info("relaunch as admin declined or failed");
      return;
    }
    // Выходим немедленно: ядро слушает фиксированные порты, и если этот процесс
    // переживёт старт нового, тот подключится к уже поднятому ядру и снова
    // окажется без прав.
    loggy.info("relaunching as admin");
    exit(0);
  }

  /// Таймаут закрытия сервисов ядра («close connection: ... timed out after 10s»).
  /// Возникает, когда зависшие соединения (обычно UDP) не закрылись за отведённые
  /// ядру 10с — после таймаута ядро всё равно останавливается принудительно,
  /// туннель разобран. Для пользователя это не сбой, диалог не показываем.
  static bool _isBenignCloseTimeout(Object err) {
    final s = err.toString();
    return s.contains("timed out") && s.contains("close");
  }

  Future<void> _disconnect() async {
    await _connectionRepo.disconnect().mapLeft((err) {
      loggy.warning("error disconnecting", err);
      if (_isBenignCloseTimeout(err)) {
        // Остановка фактически произошла — не пугаем пользователя диалогом
        // и не переводим состояние в ошибку.
        return;
      }
      ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      state = AsyncError(err, StackTrace.current);
    }).run();
  }

  void _deletePausedMarker() {
    try {
      final dirs = ref.read(appDirectoriesProvider).valueOrNull;
      if (dirs == null) return;
      final f = File(p.join(dirs.baseDir.path, 'paused.flag'));
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

@Riverpod(keepAlive: true)
bool serviceRunning(Ref ref) {
  // ref.watch(coreRestartSignalProvider);
  return ref.watch(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
}

class SingleCall {
  bool _running = false;

  Future<T> run<T>(Future<T> Function() task, {required T onIgnored}) async {
    if (_running) return onIgnored;

    _running = true;
    try {
      return await task();
    } finally {
      _running = false;
    }
  }
}
