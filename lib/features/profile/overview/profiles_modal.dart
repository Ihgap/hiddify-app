import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/profiles_update_notifier.dart';
import 'package:hiddify/features/profile/overview/profiles_notifier.dart';
import 'package:hiddify/features/profile/widget/profile_tile.dart';
import 'package:hiddify/features/proxy/active/ip_widget.dart';
import 'package:hiddify/features/proxy/overview/known_delays.dart';
import 'package:hiddify/features/proxy/overview/offline_servers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProfilesModal extends HookConsumerWidget {
  const ProfilesModal({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final asyncProfiles = ref.watch(profilesNotifierProvider);
    final servers = ref.watch(offlineServersProvider).valueOrNull ?? const <String>[];

    ref.listen(profilesNotifierProvider, (_, next) {
      if (next.hasValue && next.value!.isEmpty) {
        if (context.canPop()) context.pop();
      }
    });

    // Запоминаем выбор (сервер или «Автоматически»=lowest), поднимаем VPN и
    // закрываем лист. Применит выбор глобальный listener в App.
    void connectAndClose(String pendingTagDisplay, String label) {
      rememberManualServer(ref, pendingTagDisplay);
      ref.read(pendingServerSelectionProvider.notifier).state = pendingTagDisplay;
      ref.read(connectionNotifierProvider.notifier).toggleConnection();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Подключение: $label…'), duration: const Duration(seconds: 2)),
      );
      if (context.canPop()) context.pop();
    }

    return SafeArea(
      child: asyncProfiles.when(
        // Высота — по контенту (без лишнего пространства), но не выше 85% экрана.
        data: (data) => ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Подписка (профиль)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: Column(
                    children: [
                      for (final profile in data)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ProfileTile(profile: profile),
                        ),
                    ],
                  ),
                ),

                // Список серверов под подпиской (как раскрытый список)
                if (servers.isNotEmpty) ...[
                  // «Автоматически» — url-test (lowest), подключение к лучшему серверу.
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.bolt_rounded, size: 28),
                    title: const Text('Автоматически'),
                    subtitle: const Text('Лучший сервер по пингу'),
                    trailing: const Icon(Icons.power_settings_new_rounded, size: 18),
                    onTap: () => connectAndClose('lowest', 'Автоматически'),
                  ),
                  // servers — сырые имена из подписки: у резерва «по спискам»
                  // в теге есть служебная метка §reserve§ (её понимает ядро).
                  // В UI и в выборе она не нужна — App матчит по tagDisplay,
                  // который тоже без метки, иначе резерв вручную не выбрался бы.
                  for (final name in servers.map(stripTagMarks))
                    ListTile(
                      dense: true,
                      leading: IPCountryFlag(countryCode: countryCodeFromFlagEmoji(name), size: 34),
                      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          KnownDelayLabel(serverName: name),
                          const SizedBox(width: 10),
                          const Icon(Icons.power_settings_new_rounded, size: 18),
                        ],
                      ),
                      onTap: () => connectAndClose(name, name),
                    ),
                ],

                const Divider(height: 12),

                // Кнопки управления подпиской (как было по умолчанию)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(bottom: 8, top: 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        label: Text(t.common.sort, maxLines: 1, overflow: TextOverflow.ellipsis),
                        icon: const Icon(Icons.sort_rounded),
                        onPressed: () => ref.read(dialogNotifierProvider.notifier).showSortProfiles(),
                      ),
                      FilledButton.icon(
                        label: Text(t.pages.profiles.updateSubscriptions, maxLines: 1, overflow: TextOverflow.ellipsis),
                        icon: const Icon(Icons.update_rounded),
                        onPressed: () => ref.read(foregroundProfilesUpdateNotifierProvider.notifier).trigger(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        loading: () => const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, stackTrace) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t.presentShortError(error)),
        ),
      ),
    );
  }
}
