import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/auto_start/notifier/auto_start_notifier.dart';
import 'package:hiddify/features/common/general_pref_tiles.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/widget/preference_tile.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:humanizer/humanizer.dart';

class GeneralPage extends HookConsumerWidget {
  const GeneralPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    return Scaffold(
      appBar: AppBar(title: Text(t.pages.settings.general.title)),
      body: ListView(
        children: [
          // Режим работы VPN: выбран ровно один из трёх (radio). Лестница
          // «надёжность → скорость», каждому режиму — свой TUN-стек
          // (ConfigOptions.resolveTunStack).
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 0),
            child: Text(
              'Режим работы',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          RadioGroup<VpnMode>(
            groupValue: ref.watch(ConfigOptions.vpnMode),
            onChanged: (value) async {
              if (value != null) await ref.read(ConfigOptions.vpnMode.notifier).update(value);
            },
            child: const Column(
              children: [
                RadioListTile<VpnMode>(
                  value: VpnMode.compatibility,
                  title: Text('Режим совместимости'),
                  subtitle: Text(
                    'Самый надёжный режим — работает стабильно на любых устройствах. '
                    'Выбирайте, если в других режимах какие-то сайты или приложения '
                    'перестали открываться.',
                  ),
                  secondary: Icon(Icons.healing_rounded),
                ),
                RadioListTile<VpnMode>(
                  value: VpnMode.fast,
                  title: Text('Быстрый режим'),
                  subtitle: Text(
                    'Заметно быстрее, при этом достаточно стабильный. Подходит '
                    'большинству устройств — попробуйте, и если всё работает, '
                    'оставляйте его.',
                  ),
                  secondary: Icon(Icons.rocket_launch_rounded),
                ),
                RadioListTile<VpnMode>(
                  value: VpnMode.maxSpeed,
                  title: Text('Максимальная скорость'),
                  subtitle: Text(
                    'Самый быстрый режим, но работает не на всех устройствах. Если '
                    'после включения появились проблемы с интернетом — вернитесь на '
                    '«Быстрый» или «Режим совместимости».',
                  ),
                  secondary: Icon(Icons.bolt_rounded),
                ),
              ],
            ),
          ),
          const Divider(),
          const LocalePrefTile(),
          const ThemeModePrefTile(),
          if (PlatformUtils.isAndroid) ...[
            SwitchListTile.adaptive(
              title: Text(t.pages.settings.general.dynamicNotification),
              subtitle: const Text('Немного расходует батарею'),
              secondary: const Icon(Icons.speed_rounded),
              value: ref.watch(Preferences.dynamicNotification),
              onChanged: ref.read(Preferences.dynamicNotification.notifier).update,
            ),
            SwitchListTile.adaptive(
              title: Text(t.pages.settings.general.hapticFeedback),
              secondary: const Icon(Icons.vibration_rounded),
              value: ref.watch(hapticServiceProvider),
              onChanged: ref.read(hapticServiceProvider.notifier).updatePreference,
            ),
          ],
          if (PlatformUtils.isDesktop) ...[
            const ClosingPrefTile(),
            SwitchListTile.adaptive(
              title: Text(t.pages.settings.general.autoStart),
              secondary: const Icon(Icons.auto_mode_rounded),
              value: ref.watch(autoStartNotifierProvider).asData!.value,
              onChanged: (value) async => value
                  ? await ref.read(autoStartNotifierProvider.notifier).enable()
                  : await ref.read(autoStartNotifierProvider.notifier).disable(),
            ),
            SwitchListTile.adaptive(
              title: Text(t.pages.settings.general.silentStart),
              secondary: const Icon(Icons.visibility_off_rounded),
              value: ref.watch(Preferences.silentStart),
              onChanged: ref.read(Preferences.silentStart.notifier).update,
            ),
          ],
          if (PlatformUtils.isAndroid) const BatteryOptimizationWidget(),
          SwitchListTile.adaptive(
            title: const Text('Логи'),
            subtitle: const Text(
              'По умолчанию выключены ради экономии заряда. Включайте только для '
              'диагностики: запись логов заметно расходует батарею. Изменение '
              'применится после переподключения VPN.',
            ),
            secondary: const Icon(Icons.article_rounded),
            value: ref.watch(ConfigOptions.enableLogs),
            onChanged: (value) async => await ref.read(ConfigOptions.enableLogs.notifier).update(value),
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.general.memoryLimit),
            subtitle: Text(t.pages.settings.general.memoryLimitMsg),
            secondary: const Icon(Icons.memory_rounded),
            value: !ref.watch(Preferences.disableMemoryLimit),
            onChanged: (value) async => await ref.read(Preferences.disableMemoryLimit.notifier).update(!value),
          ),
          ListTile(
            title: Text(t.pages.settings.general.urlTestInterval),
            subtitle: Text(ref.watch(ConfigOptions.urlTestInterval).toApproximateTime(isRelativeToNow: false)),
            leading: const Icon(Icons.timer_rounded),
            onTap: () async => await ref
                .read(dialogNotifierProvider.notifier)
                .showSettingSlider(
                  title: t.pages.settings.general.urlTestInterval,
                  initialValue: ref.watch(ConfigOptions.urlTestInterval).inMinutes.coerceIn(0, 60).toDouble(),
                  onReset: ref.read(ConfigOptions.urlTestInterval.notifier).reset,
                  min: 1,
                  max: 60,
                  divisions: 60,
                  labelGen: (value) => Duration(minutes: value.toInt()).toApproximateTime(isRelativeToNow: false),
                )
                .then((value) async {
                  if (value == null) return;
                  await ref.read(ConfigOptions.urlTestInterval.notifier).update(Duration(minutes: value.toInt()));
                }),
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.general.useXrayCoreWhenPossible),
            subtitle: Text(t.pages.settings.general.useXrayCoreWhenPossibleMsg),
            secondary: const Icon(Icons.extension_rounded),
            value: ref.watch(ConfigOptions.useXrayCoreWhenPossible),
            onChanged: ref.read(ConfigOptions.useXrayCoreWhenPossible.notifier).update,
          ),
        ],
      ),
    );
  }
}
