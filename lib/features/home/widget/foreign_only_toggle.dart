import 'package:flutter/material.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/data/server_routing.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Переключатель «Проксировать только зарубежный трафик».
///
/// Источник правды — регион (RU). Само правило маршрутизации задаётся СЕРВЕРОМ
/// (foreignRoutingProvider, приходит в /app/activate) и инжектится в конфиг в
/// config_option_repository, когда регион = RU. Тумблер лишь хранит состояние.
/// При выключении весь трафик идёт через VPN.
class ForeignOnlyToggle extends ConsumerWidget {
  const ForeignOnlyToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final enabled = ref.watch(ConfigOptions.region) == Region.ru;

    Future<void> setEnabled(bool value) async {
      await ref.read(ConfigOptions.region.notifier).update(value ? Region.ru : Region.other);
      // Чистим устаревшее персистентное правило старого подхода (теперь правило
      // приходит с сервера и инжектится в конфиг, а не хранится в файле).
      final notifier = ref.read(rulesNotifierProvider.notifier);
      final foreignName = (ref.read(foreignRoutingProvider)['name'] as String?) ?? 'РФ напрямую';
      final stale = ref.read(rulesNotifierProvider).where((r) => r.name == foreignName).toList();
      for (final r in stale) {
        await notifier.deleteRule(r.listOrder);
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.public_rounded, size: 22),
          const SizedBox(width: 12),
          // «Резиновый» текст: целевой размер 22, но FittedBox ужимает его под
          // доступную ширину, чтобы строка целиком влезала на любом экране.
          const Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                'Только зарубежный трафик',
                maxLines: 1,
                softWrap: false,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Switch(value: enabled, onChanged: setEnabled),
        ],
      ),
    );
  }
}
