import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Ручная проверка обновлений. Живёт отдельным виджетом, потому что нужна и в
/// «Общих» (страница «О программе» скрыта от пользователей), и на самой
/// странице «О программе».
///
/// Это единственный способ проверить обновление принудительно: автоматическая
/// проверка идёт только при запуске приложения и не чаще раза в трое суток.
class CheckForUpdateTile extends HookConsumerWidget {
  const CheckForUpdateTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final appInfo = ref.watch(appInfoProvider).requireValue;
    final appUpdate = ref.watch(appUpdateNotifierProvider);

    ref.listen(appUpdateNotifierProvider, (_, next) async {
      if (!context.mounted) return;
      switch (next) {
        case AppUpdateStateAvailable(:final versionInfo) || AppUpdateStateIgnored(:final versionInfo):
          return await ref
              .read(dialogNotifierProvider.notifier)
              .showNewVersion(currentVersion: appInfo.presentVersion, newVersion: versionInfo, canIgnore: false);
        case AppUpdateStateError(:final error):
          return CustomToast.error(t.presentShortError(error)).show(context);
        case AppUpdateStateNotAvailable():
          return CustomToast.success(t.pages.about.notAvailableMsg).show(context);
      }
    });

    // Сборки из Play обновляются самим Play — своя проверка там запрещена.
    if (!appInfo.release.allowCustomUpdateChecker) return const SizedBox.shrink();

    return ListTile(
      title: Text(t.pages.about.checkForUpdate),
      subtitle: Text('Установлена версия ${appInfo.presentVersion}'),
      leading: const Icon(Icons.system_update_alt_rounded),
      trailing: switch (appUpdate) {
        AppUpdateStateChecking() => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator()),
        _ => const Icon(FluentIcons.arrow_sync_24_regular),
      },
      onTap: () async {
        await ref.read(appUpdateNotifierProvider.notifier).check();
      },
    );
  }
}
