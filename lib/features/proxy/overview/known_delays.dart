import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Последние известные задержки серверов: пинг в списке ещё до подключения.
///
/// Почему не меряем напрямую при выключенном VPN. Единственное, что доступно
/// клиенту без поднятого туннеля, — TCP-хендшейк до адреса из ссылки. Но часть
/// серверов стоит за relay (nginx stream, см. scripts/setup-relay.sh в боте):
/// relay отвечает на SYN сам и только потом открывает второе соединение к
/// выходу. Такой замер показал бы плечо «телефон → relay» и занизил бы реальный
/// путь в разы — то есть врал бы ровно там, где точность и нужна. Поэтому здесь
/// лежат честные туннельные замеры: они сняты ядром по всему пути, включая relay.
class KnownDelay {
  const KnownDelay(this.delay, this.at);

  final int delay;
  final DateTime at;
}

/// Замеры старше этого срока не показываем: сеть у человека давно другая.
const _staleAfter = Duration(days: 3);

/// Как часто разрешаем писать в SharedPreferences. Ядро шлёт обновления группы
/// пачками (debounce 500 мс), сохранять каждую — лишние записи на диск.
const _writeEvery = Duration(seconds: 20);

DateTime? _lastWrite;

final knownDelaysProvider = PreferencesNotifier.create<Map<String, KnownDelay>, String>(
  "known_server_delays",
  const {},
  mapFrom: _decode,
  mapTo: _encode,
);

Map<String, KnownDelay> _decode(String raw) {
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return {
      for (final e in decoded.entries)
        if (e.value case {'d': final int d, 't': final int t}) e.key: KnownDelay(d, DateTime.fromMillisecondsSinceEpoch(t)),
    };
  } catch (_) {
    // Битый или устаревший формат — начинаем с чистого листа, это всего лишь кэш.
    return const {};
  }
}

String _encode(Map<String, KnownDelay> value) =>
    jsonEncode({for (final e in value.entries) e.key: {'d': e.value.delay, 't': e.value.at.millisecondsSinceEpoch}});

/// Запоминает свежие замеры из потока ядра. Вызывается из слушателя в App,
/// пока туннель поднят.
void rememberDelays(WidgetRef ref, OutboundGroup group) {
  final now = DateTime.now();
  if (_lastWrite != null && now.difference(_lastWrite!) < _writeEvery) return;

  final current = Map<String, KnownDelay>.from(ref.read(knownDelaysProvider));
  var changed = false;
  for (final item in group.items) {
    // Группы («Авто», balance) пропускаем: у них не свой замер, а чужой.
    if (item.isGroup) continue;
    final delay = item.urlTestDelay;
    // 0 — ещё не мерили либо значение из кэша ядра, 65535 — таймаут.
    if (delay <= 0 || delay > 65000) continue;
    final name = item.tagDisplay;
    if (name.isEmpty) continue;
    if (current[name]?.delay != delay) changed = true;
    current[name] = KnownDelay(delay, now);
  }
  if (!changed) return;

  _lastWrite = now;
  ref.read(knownDelaysProvider.notifier).update(current);
}

/// Пинг сервера по последнему известному замеру. Пусто, если сервер ещё ни разу
/// не мерили или замер протух.
class KnownDelayLabel extends ConsumerWidget {
  const KnownDelayLabel({super.key, required this.serverName});

  /// Имя сервера как в списке — без служебных меток (tagDisplay).
  final String serverName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final known = ref.watch(knownDelaysProvider)[serverName];
    if (known == null || DateTime.now().difference(known.at) > _staleAfter) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Text(
      "${known.delay} ms",
      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}
