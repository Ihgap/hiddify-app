import 'dart:math';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/features/proxy/overview/offline_servers.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/proxy/widget/proxy_tile.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProxiesOverviewPage extends HookConsumerWidget with PresLogger {
  const ProxiesOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    final proxies = ref.watch(proxiesOverviewNotifierProvider);
    final sortBy = ref.watch(proxiesSortNotifierProvider);

    // final selectActiveProxyMutation = useMutation(
    //   initialOnFailure: (error) => CustomToast.error(t.presentShortError(error)).show(context),
    // );

    return Scaffold(
      appBar: AppBar(
        title: Text(t.pages.proxies.title),
        actions: [
          PopupMenuButton<ProxiesSort>(
            initialValue: sortBy,
            onSelected: ref.read(proxiesSortNotifierProvider.notifier).update,
            icon: const Icon(FluentIcons.arrow_sort_24_regular),
            tooltip: t.pages.proxies.sort,
            itemBuilder: (context) {
              return [...ProxiesSort.values.map((e) => PopupMenuItem(value: e, child: Text(e.present(t))))];
            },
          ),
          const Gap(8),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async => await ref.read(proxiesOverviewNotifierProvider.notifier).urlTest("select"),
        tooltip: t.pages.proxies.testDelay,
        child: const Icon(FluentIcons.flash_24_filled),
      ),
      body: proxies.when(
        data: (group) {
          if (group == null) return Center(child: Text(t.pages.proxies.empty));

          // Используем url-test ("lowest", авто-лучший), а round-robin ("balance")
          // скрываем — он нам не нужен.
          final items = group.items
              .where((e) => e.tagDisplay.trim().toLowerCase() != 'balance')
              .toList();

          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final crossAxisCount = PlatformUtils.isMobile && width < 600 ? 1 : max(1, (width / 268).floor());
              return GridView.builder(
                padding: const EdgeInsets.only(bottom: 86),
                itemCount: items.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisExtent: 72,
                ),
                itemBuilder: (context, index) {
                  final proxy = items[index];
                  // url-test показываем как «Автоматически».
                  final isAuto = proxy.tagDisplay.trim().toLowerCase() == 'lowest';
                  return ProxyTile(
                    proxy,
                    selected: group.selected == proxy.tag,
                    titleOverride: isAuto ? 'Автоматически' : null,
                    onTap: () async {
                      // Выбор руками — запоминаем, чтобы вернуть после
                      // перезапуска (память ядра теряет его при обновлении
                      // подписки, см. Preferences.lastSelectedServer).
                      rememberManualServer(ref, proxy.tagDisplay);
                      await ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, proxy.tag);
                    },
                  );
                },
              );
            },
          );
        },
        // VPN отключён → ядро не отдаёт прокси. Вместо ошибки показываем список
        // серверов из сохранённой подписки (read-only), как v2rayTun/Happ.
        error: (error, stackTrace) => error is ServiceNotRunning
            ? const OfflineServerList()
            : Center(child: Text(t.presentShortError(error))),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
