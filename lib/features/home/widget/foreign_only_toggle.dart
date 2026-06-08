import 'package:flutter/material.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Имя route-правила «РФ напрямую» — по нему находим/удаляем его.
const _ruDirectRuleName = 'РФ напрямую';

/// Переключатель «Проксировать только зарубежный трафик».
///
/// При включении:
///  - регион = RU (ядро применяет домашние правила РФ для DNS/маршрутов);
///  - добавляется route-правило: российские IP (geoip-ru) идут НАПРЯМУЮ,
///    остальной трафик — через VPN (по умолчанию).
/// При выключении регион сбрасывается и правило удаляется — весь трафик в VPN.
///
/// Изменение применяется при следующем подключении/реконнекте.
class ForeignOnlyToggle extends ConsumerWidget {
  const ForeignOnlyToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final enabled = ref.watch(ConfigOptions.region) == Region.ru;

    Future<void> setEnabled(bool value) async {
      await ref.read(ConfigOptions.region.notifier).update(value ? Region.ru : Region.other);
      final notifier = ref.read(rulesNotifierProvider.notifier);
      final existing = ref.read(rulesNotifierProvider).where((r) => r.name == _ruDirectRuleName).toList();
      if (value) {
        // Сначала удаляем СТАРЫЕ версии правила (после обновления приложения
        // оно может остаться от прежней сборки без доменных суффиксов), затем
        // добавляем актуальное — так правило самообновляется.
        for (final r in existing) {
          await notifier.deleteRule(r.listOrder);
        }
        await notifier.addRule(
          Rule(
            enabled: true,
            name: _ruDirectRuleName,
            outbound: Outbound.direct,
            // По домену (.ru/.рф) — чтобы РФ-сайты шли напрямую независимо от
            // того, какой IP вернул geo-DNS (иначе yandex.ru резолвится в
            // зарубежный IP и уходит в VPN). geoip-ru — для РФ-сервисов на
            // зарубежных доменах, но российских IP.
            domainSuffixes: ['.ru', '.рф'],
            ruleSets: ['geoip-ru'],
          ),
        );
      } else {
        for (final r in existing) {
          await notifier.deleteRule(r.listOrder);
        }
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
