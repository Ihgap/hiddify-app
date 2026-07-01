import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/app_trial/app_trial_controller.dart';
import 'package:hiddify/features/app_trial/subscription_banner.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/home/widget/foreign_only_toggle.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/widget/profile_tile.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sliver_tools/sliver_tools.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    // Синхронизация встроенной подписки: старт + (через App.onResume) возврат из фона.
    final syncState = ref.watch(subscriptionSyncProvider);
    final activeProfile = ref.watch(activeProfileProvider);
    // Первый запуск: профиля ещё нет, а синк скачивает подписку — держим экран
    // загрузки, чтобы не мелькал пустой список и подписка появилась сразу.
    final hasAnyProfile = ref.watch(hasAnyProfileProvider).valueOrNull ?? false;
    final firstLaunchLoading = !hasAnyProfile && syncState.isLoading;

    return Scaffold(
      appBar: AppBar(
        // leading: (RootScaffold.stateKey.currentState?.hasDrawer ?? false) && showDrawerButton(context)
        //     ? DrawerButton(
        //         onPressed: () {
        //           RootScaffold.stateKey.currentState?.openDrawer();
        //         },
        //       )
        //     : null,
        title: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: t.common.appTitle),
              const TextSpan(text: " "),
              const WidgetSpan(child: AppVersionLabel(), alignment: PlaceholderAlignment.middle),
            ],
          ),
        ),
        actions: [
          // Переключатель VPN/Прокси убран с главного экрана (остаётся в
          // Настройки → Inbound → Service mode).
          Semantics(
            key: const ValueKey("profile_add_button"),
            label: t.pages.profiles.add,
            child: IconButton(
              icon: Icon(Icons.add_rounded, color: theme.colorScheme.primary),
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
            ),
          ),
          const Gap(8),
        ],
      ),
      body: Container(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: Transform.translate(
                offset: const Offset(0, 0), // map vertically centered
                child: Transform.scale(
                  scale: 1.5, // zoom in 1.5x
                  child: Image.asset(
                    'assets/images/world_map.png',
                    fit: BoxFit.fitWidth, // always fill full width, never crop sides
                    alignment: const Alignment(0, -0.2),
                    opacity: const AlwaysStoppedAnimation(0.09),
                    color: theme.brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: .15)
                        : Colors.grey,
                    colorBlendMode: theme.brightness == Brightness.dark
                        ? BlendMode.srcIn
                        : BlendMode.srcATop,
                  ),
                ),
              ),
            ),
            if (firstLaunchLoading)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const Gap(16),
                    Text('Загрузка подписки…', style: theme.textTheme.bodyMedium),
                  ],
                ),
              )
            else
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 600, // Set the maximum width here
                  ),
                  child: CustomScrollView(
                  slivers: [
                    // switch (activeProfile) {
                    // AsyncData(value: final profile?) =>
                    MultiSliver(
                      children: [
                        // const Gap(100),
                        const SliverToBoxAdapter(child: SubscriptionBanner()),
                        switch (activeProfile) {
                          AsyncData(value: final profile?) => ProfileTile(
                            profile: profile,
                            isMain: true,
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            color: Theme.of(context).colorScheme.surfaceContainer,
                          ),
                          _ => const Text(""),
                        },
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: SafeArea(
                            top: false,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: const [
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [ConnectionButton(), ActiveProxyDelayIndicator()],
                                  ),
                                ),
                                ActiveProxyFooter(),
                                Gap(8),
                                ForeignOnlyToggle(),
                                Gap(12),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    // AsyncData() => switch (hasAnyProfile) {
                    //     AsyncData(value: true) => const EmptyActiveProfileHomeBody(),
                    //     _ => const EmptyProfilesHomeBody(),
                    //   },
                    // AsyncError(:final error) => SliverErrorBodyPlaceholder(t.presentShortError(error)),
                    // _ => const SliverToBoxAdapter(),
                    // },
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final version = ref.watch(appInfoProvider).requireValue.presentVersion;
    if (version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Container(
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          version,
          textDirection: TextDirection.ltr,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}
