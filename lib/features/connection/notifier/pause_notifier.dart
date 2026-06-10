import 'dart:io';

import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

/// Имя файла-маркера, который натив создаёт при «Паузе» (см. BoxService.kt,
/// функция pauseService / setPausedMarker). Лежит в baseDir, общей для натива
/// (filesDir) и Flutter (getApplicationSupportDirectory).
const _pausedMarkerName = 'paused.flag';

/// true, если VPN на «Паузе»: ядро остановлено кнопкой «Пауза» в уведомлении
/// (маркер-файл присутствует), а не обычным «Стоп».
///
/// «Пауза» имеет смысл только когда ядро не запущено — поэтому маркер
/// учитываем лишь в состоянии Disconnected. Это же страхует от «залипшего»
/// маркера: как только соединение поднимется, статус перестанет быть «Пауза».
final pausedProvider = Provider<bool>((ref) {
  final status = ref.watch(connectionNotifierProvider).valueOrNull;
  if (status is! Disconnected) return false;
  final dirs = ref.watch(appDirectoriesProvider).valueOrNull;
  if (dirs == null) return false;
  try {
    return File(p.join(dirs.baseDir.path, _pausedMarkerName)).existsSync();
  } catch (_) {
    return false;
  }
});
