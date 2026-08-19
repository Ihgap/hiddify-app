import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/widget/shimmer_skeleton.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ActiveProxyDelayIndicator extends HookConsumerWidget with InfraLogger {
  const ActiveProxyDelayIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final theme = Theme.of(context);

    // Хуки — до любых ранних выходов, иначе поедет их порядок между сборками.
    final measuring = useState(false);
    final lastStamp = useRef<int?>(null);
    final guard = useRef<Timer?>(null);
    useEffect(() => () => guard.value?.cancel(), const []);

    final proxy = activeProxy is AsyncData ? activeProxy.value : null;

    // Ядро на запрос теста отвечает сразу, а результат кладёт в поток позже
    // (замер — это серия проб, около секунды). Ориентируемся на отметку времени
    // последнего замера: так индикатор гаснет и тогда, когда новое значение
    // совпало с прежним — а теперь, с медианой серии, так будет часто.
    final stamp = proxy != null && proxy.hasUrlTestTime() ? proxy.urlTestTime.toDateTime().millisecondsSinceEpoch : null;
    useEffect(() {
      if (stamp != null && lastStamp.value != stamp) {
        lastStamp.value = stamp;
        guard.value?.cancel();
        measuring.value = false;
      }
      return null;
    }, [stamp]);

    if (proxy == null) {
      return const SizedBox(); // Avoid building widget if data is not available
    }

    final delay = proxy.urlTestDelay;
    final timeout = delay > 65000;

    Future<void> measure() async {
      measuring.value = true;
      // Страховка: если результат не придёт (сервер молчит, ядро перезапустили),
      // индикатор не должен крутиться вечно.
      guard.value?.cancel();
      guard.value = Timer(const Duration(seconds: 15), () {
        if (context.mounted) measuring.value = false;
      });
      try {
        await ref.read(activeProxyNotifierProvider.notifier).urlTest("");
      } catch (e) {
        loggy.error("Error during URL test: $e");
        guard.value?.cancel();
        if (context.mounted) measuring.value = false;
      }
    }

    return Center(
      child: InkWell(
        // Повторный тап во время замера игнорируем: ядро всё равно отбросит
        // дубль, а человеку это выглядело как «нажал, а число не изменилось».
        onTap: measuring.value ? null : measure,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(FluentIcons.wifi_1_24_regular),
              const Gap(8),
              if (measuring.value && delay > 0 && !timeout) ...[
                // Прежнее значение приглушаем, а не убираем: видно, что идёт
                // новый замер, и при этом экран не прыгает в пустоту.
                Opacity(
                  opacity: .4,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: delay.toString(),
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const TextSpan(text: " ms"),
                      ],
                    ),
                  ),
                ),
                const Gap(8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
                ),
              ] else if (measuring.value)
                Semantics(label: t.pages.proxies.delay.testing, child: const ShimmerSkeleton(width: 48, height: 18))
              else if (delay > 0)
                Text.rich(
                  semanticsLabel: timeout ? t.pages.proxies.delay.timeout : t.pages.proxies.delay.result(delay: delay),
                  TextSpan(
                    children: [
                      if (timeout)
                        TextSpan(
                          text: t.common.timeout,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.error,
                          ),
                        )
                      else ...[
                        TextSpan(
                          text: delay.toString(),
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const TextSpan(text: " ms"),
                      ],
                    ],
                  ),
                )
              else
                Semantics(label: t.pages.proxies.delay.testing, child: const ShimmerSkeleton(width: 48, height: 18)),
            ],
          ),
        ),
      ),
    );
  }
}
