import 'dart:convert';

import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _routingPrefKey = 'app_foreign_routing';

/// Встроенный дефолт правила «только зарубежный трафик» — пока с сервера не
/// пришло актуальное (первый офлайн-запуск). Сервер может его переопределить.
const defaultForeignRouting = <String, dynamic>{
  'version': 0,
  'name': 'РФ напрямую',
  'outbound': 'direct',
  'domain_suffixes': ['.ru', '.рф'],
  'rule_sets': ['geoip-ru'],
  'direct_dns': '77.88.8.8',
};

/// Текущее правило маршрутизации, управляемое С СЕРВЕРА. Инициализируется из
/// SharedPreferences, обновляется при активации (/app/activate → routing).
final foreignRoutingProvider = StateProvider<Map<String, dynamic>>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider).requireValue;
  final raw = prefs.getString(_routingPrefKey);
  if (raw != null) {
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      // повреждённое значение — откатываемся на дефолт
    }
  }
  return defaultForeignRouting;
});

/// Сохраняет пришедшее с сервера правило и обновляет провайдер (если оно новее
/// или версия не указана — просто перезаписываем).
Future<void> saveForeignRouting(Ref ref, Map<String, dynamic> routing) async {
  final current = ref.read(foreignRoutingProvider);
  final newVer = (routing['version'] as num?)?.toInt() ?? -1;
  final curVer = (current['version'] as num?)?.toInt() ?? -1;
  // Обновляем только при СТРОГО новой версии — иначе каждое /app/activate
  // дёргало бы реконнект (новый объект Map → пересборка конфига).
  if (newVer <= curVer) return;
  final prefs = ref.read(sharedPreferencesProvider).requireValue;
  await prefs.setString(_routingPrefKey, jsonEncode(routing));
  ref.read(foreignRoutingProvider.notifier).state = routing;
}

/// Строит route-правило (proto) из серверного описания.
Rule foreignRoutingRule(Map<String, dynamic> r, int listOrder) {
  final outbound = switch ((r['outbound'] as String?) ?? 'direct') {
    'proxy' => Outbound.proxy,
    'block' => Outbound.block,
    _ => Outbound.direct,
  };
  return Rule(
    listOrder: listOrder,
    enabled: true,
    name: (r['name'] as String?) ?? 'РФ напрямую',
    outbound: outbound,
    domainSuffixes: ((r['domain_suffixes'] as List?) ?? const []).map((e) => '$e'),
    ruleSets: ((r['rule_sets'] as List?) ?? const []).map((e) => '$e'),
  );
}
