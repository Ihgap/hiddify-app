import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/log/data/log_parser.dart';
import 'package:hiddify/features/log/data/log_path_resolver.dart';
import 'package:hiddify/features/log/model/log_entity.dart';
import 'package:hiddify/features/log/model/log_failure.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/utils/custom_loggers.dart';

abstract interface class LogRepository {
  TaskEither<LogFailure, Unit> init();
  Stream<Either<LogFailure, List<LogEntity>>> watchLogs();
  TaskEither<LogFailure, Unit> clearLogs();
}

class LogRepositoryImpl with ExceptionHandler, InfraLogger implements LogRepository {
  LogRepositoryImpl({required this.singbox, required this.logPathResolver});

  final HiddifyCoreService singbox;
  final LogPathResolver logPathResolver;

  @override
  TaskEither<LogFailure, Unit> init() {
    return exceptionHandler(() async {
      if (!kIsWeb) {
        if (!await logPathResolver.directory.exists()) {
          await logPathResolver.directory.create(recursive: true);
        }
        if (await logPathResolver.coreFile().exists()) {
          await logPathResolver.coreFile().writeAsString("");
        } else {
          await logPathResolver.coreFile().create(recursive: true);
        }
        if (await logPathResolver.appFile().exists()) {
          await logPathResolver.appFile().writeAsString("");
        } else {
          await logPathResolver.appFile().create(recursive: true);
        }
      }
      return right(unit);
    }, LogUnexpectedFailure.new);
  }

  @override
  Stream<Either<LogFailure, List<LogEntity>>> watchLogs() {
    // Логи движка sing-box приходят штатно через gRPC-стрим: в ядре снят guard
    // `if s.debug` (started_service.go), поэтому движок отдаёт соединения/DNS/
    // маршрутизацию/ошибки в logObserver, который слушает этот стрим. Прежний
    // костыль с опросом файла data/box.log каждые 2 сек убран — он давал дубли
    // и задержку. Уровень детализации задаёт движок (logLevel = info).
    final logs = <LogEntity>[];
    final controller = StreamController<Either<LogFailure, List<LogEntity>>>();

    final grpcSub = singbox
        .watchLogs(logPathResolver.coreFile().path)
        .listen(
          (grpcMessages) {
            logs.addAll(grpcMessages.map(LogParser.parseLogProto));
            if (logs.length > 500) logs.removeRange(0, logs.length - 500);
            controller.add(right(List.of(logs)));
          },
          onError: (e) => loggy.warning("gRPC log stream error: $e"),
        );

    controller.onCancel = grpcSub.cancel;

    return controller.stream;
  }

  @override
  TaskEither<LogFailure, Unit> clearLogs() {
    return exceptionHandler(() => singbox.clearLogs().mapLeft(LogFailure.unexpected).run(), LogFailure.unexpected);
  }
}
