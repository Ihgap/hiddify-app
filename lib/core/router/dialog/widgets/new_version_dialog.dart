import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/app_trial/device_identity.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

class NewVersionDialog extends HookConsumerWidget with PresLogger {
  NewVersionDialog(this.currentVersion, this.newVersion, {super.key, this.canIgnore = true});

  final String currentVersion;
  final RemoteVersionEntity newVersion;
  final bool canIgnore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(t.dialogs.newVersion.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.dialogs.newVersion.msg),
          const Gap(8),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: t.dialogs.newVersion.currentVersion, style: theme.textTheme.bodySmall),
                TextSpan(text: currentVersion, style: theme.textTheme.labelMedium),
              ],
            ),
          ),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: t.dialogs.newVersion.newVersion, style: theme.textTheme.bodySmall),
                TextSpan(text: newVersion.presentVersion, style: theme.textTheme.labelMedium),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (canIgnore)
          TextButton(
            onPressed: () async {
              await ref.read(appUpdateNotifierProvider.notifier).ignoreRelease(newVersion);
              if (context.mounted) context.pop();
            },
            child: Text(t.common.ignore),
          ),
        TextButton(onPressed: context.pop, child: Text(t.common.later)),
        TextButton(
          onPressed: () async {
            // Установка из Google Play обновляется ТОЛЬКО через Play: APK с
            // наших источников подписан другим ключом, и Android заблокирует
            // установку поверх («Приложение заблокировано для защиты…»).
            if (await DeviceIdentity.installedFromPlay()) {
              final pkg = (await PackageInfo.fromPlatform()).packageName;
              await UriUtils.tryLaunch(
                Uri.parse('https://play.google.com/store/apps/details?id=$pkg'),
              );
              return;
            }
            await UriUtils.tryLaunch(Uri.parse(newVersion.url));
          },
          child: Text(t.dialogs.newVersion.updateNow),
        ),
      ],
    );
  }
}
