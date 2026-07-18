import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/stats/data/stats_data_providers.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';

part 'stats_notifier.g.dart';

@riverpod
class StatsNotifier extends _$StatsNotifier with AppLogger {
  @override
  Stream<SystemInfo> build() {
    ref.disposeDelay(const Duration(seconds: 10));
    final serviceRunning = ref.watch(serviceRunningProvider);
    if (serviceRunning) {
      // Ядро (в .aar) шлёт статистику раз в секунду. Обновлять UI так часто нет
      // смысла — дросселируем до 2 сек (leading+trailing: сразу показываем первое
      // значение и всегда отдаём последнее в окне). Косметика: снижает перерисовку.
      return ref
          .watch(statsRepositoryProvider)
          .watchStats()
          .map((event) => event.getOrElse((_) => SystemInfo.create()))
          .throttleTime(const Duration(seconds: 2), leading: true, trailing: true);
    } else {
      return Stream.value(SystemInfo.create());
    }
  }
}
