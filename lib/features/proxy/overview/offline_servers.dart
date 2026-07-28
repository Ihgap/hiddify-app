import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/ip_widget.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Сервер (его tag/имя), выбранный в офлайн-списке: применяем его после того,
/// как ядро поднимется. null — ничего не ждём. Хранит выбор между состоянием
/// «отключено» и моментом, когда прокси станут доступны.
final pendingServerSelectionProvider = StateProvider<String?>((ref) => null);

/// Список серверов из сохранённой подписки — без запущенного ядра.
///
/// Данные берём из `<id>.tmp.json` активного профиля: это base64-список
/// `vless://`-ссылок (та же подписка, что показывают v2rayTun/Happ). Имя
/// сервера — из #fragment ссылки (у нас там флаг-эмодзи + название страны).
final offlineServersProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return const [];

  final file = ref.watch(profilePathResolverProvider).tempFile(profile.id);
  if (!file.existsSync()) return const [];

  final raw = (await file.readAsString()).trim();
  if (raw.isEmpty) return const [];

  final decoded = safeDecodeBase64(raw);
  final names = <String>[];
  for (final line in decoded.split('\n')) {
    final l = line.trim();
    if (!l.contains('://')) continue;
    final hash = l.indexOf('#');
    if (hash < 0) continue;
    var name = l.substring(hash + 1);
    try {
      name = Uri.decodeComponent(name);
    } catch (_) {
      // имя не URL-encoded — берём как есть
    }
    if (name.isNotEmpty) names.add(name);
  }
  return names;
});

/// Убирает служебные метки (§reserve§, §hide§, …) из отображаемого имени —
/// как _sanitizedTag в proxy_entity и TrimTagName в ядре. offlineServersProvider
/// отдаёт сырые имена (метка нужна ShutdownFailover), поэтому чистим в UI/выборе.
String _stripTagMarks(String tag) => tag.replaceFirst(RegExp(r"\§[^]*"), "").trimRight();

/// Read-only список серверов, когда VPN отключён (ядро не запущено).
/// Выбор сервера и пинг доступны только при подключении — это ограничение
/// движка sing-box.
class OfflineServerList extends ConsumerWidget {
  const OfflineServerList({super.key, this.onServerSelected});

  /// Вызывается после тапа по серверу (после старта подключения).
  final VoidCallback? onServerSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final names = ref.watch(offlineServersProvider).valueOrNull ?? const [];

    if (names.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 18, color: theme.colorScheme.onSecondaryContainer),
              const Gap(8),
              Expanded(
                child: Text(
                  'Нажмите на сервер, чтобы подключиться к нему. Пинг появится после подключения.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 86, top: 4),
            // +1 — пункт «Автоматически» в начале списка.
            itemCount: names.length + 1,
            itemBuilder: (context, index) {
              // Запоминаем выбор и поднимаем VPN; применит listener в App.
              void connect(String pendingTagDisplay, String label) {
                ref.read(pendingServerSelectionProvider.notifier).state = pendingTagDisplay;
                ref.read(connectionNotifierProvider.notifier).toggleConnection();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Подключение: $label…'), duration: const Duration(seconds: 2)),
                );
                onServerSelected?.call();
              }

              if (index == 0) {
                return ListTile(
                  leading: const Icon(Icons.bolt_rounded, size: 32),
                  title: const Text('Автоматически'),
                  subtitle: const Text('Лучший сервер по пингу'),
                  trailing: const Icon(Icons.power_settings_new_rounded, size: 20),
                  onTap: () => connect('lowest', 'Автоматически'),
                );
              }
              // name — сырой tag из подписки (у резерва несёт §reserve§).
              // Показываем и выбираем без метки: connect кладёт имя в
              // pendingServerSelectionProvider, где App матчит по tagDisplay
              // (тоже без метки), иначе резерв вручную не выбрался бы.
              final rawName = names[index - 1];
              final display = _stripTagMarks(rawName);
              return ListTile(
                leading: IPCountryFlag(countryCode: countryCodeFromFlagEmoji(display), size: 40),
                title: Text(display, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.power_settings_new_rounded, size: 20),
                onTap: () => connect(display, display),
              );
            },
          ),
        ),
      ],
    );
  }
}
