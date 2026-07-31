import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Тихое самообновление Windows-сборки (Вариант А).
///
/// Качаем наш установщик, гасим ядро (иначе hiddify-core.dll и wintun залочены
/// и Inno не заменит файлы), запускаем Inno Setup в тихом режиме и выходим.
/// Установщик заменяет файлы и перезапускает приложение (см. [Run] в
/// inno_setup.sas). Одно окно UAC неизбежно — это машинная установка в
/// Program Files (обойти нельзя без привилегированной службы).
class _WindowsUpdater {
  Future<File> download(String url, void Function(double) onProgress) async {
    final dir = await getTemporaryDirectory();
    final target = File('${dir.path}\\TuTu4kA_VPN_update.exe');
    if (await target.exists()) {
      try {
        await target.delete();
      } catch (_) {}
    }
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
    await dio.download(
      url,
      target.path,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );
    return target;
  }

  Future<Never> launchAndExit(File installer) async {
    await Process.start(
      installer.path,
      const [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/NOCANCEL',
        '/FORCECLOSEAPPLICATIONS',
      ],
      mode: ProcessStartMode.detached,
    );
    // Даём установщику подняться и запросить UAC, затем выходим — так Inno
    // сможет заменить наш exe/dll и перезапустить приложение.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    exit(0);
  }
}

/// Показывает прогресс-диалог и проводит тихое обновление. Только Windows.
/// Возвращает управление лишь при ошибке — при успехе процесс завершается.
Future<void> runWindowsSelfUpdate(BuildContext context, WidgetRef ref) async {
  if (!Platform.isWindows) return;
  final progress = ValueNotifier<double>(0);
  final updater = _WindowsUpdater();

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Обновление'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Скачиваем и устанавливаем новую версию. '
              'Приложение перезапустится автоматически.',
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, value, _) => Column(
                children: [
                  LinearProgressIndicator(value: value == 0 ? null : value),
                  const SizedBox(height: 8),
                  Text('${(value * 100).round()}%'),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  try {
    final installer =
        await updater.download(Constants.windowsSetupUrl, (p) => progress.value = p);
    // Останавливаем VPN-ядро, иначе установщик не заменит залоченные файлы.
    await ref.read(connectionNotifierProvider.notifier).abortConnection();
    await Future<void>.delayed(const Duration(seconds: 1));
    await updater.launchAndExit(installer);
  } catch (e) {
    debugPrint('windows self-update failed: $e');
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop(); // закрыть прогресс
      await showDialog<void>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('Не удалось обновить'),
          content: const Text(
            'Не получилось скачать или запустить обновление. '
            'Попробуй ещё раз позже или скачай установщик с сайта.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
}
