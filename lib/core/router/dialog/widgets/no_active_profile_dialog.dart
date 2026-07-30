import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/app_trial/app_trial_controller.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Показывается по нажатию «Подключиться», когда нет активного профиля — то
/// есть автозагрузка встроенной подписки (subscriptionSyncProvider) не
/// отработала. Стоковый Hiddify здесь предлагал настроить свой сервер по гайду
/// hiddify.com — у нас вместо этого повтор загрузки и ссылка на наш сайт.
class NoActiveProfileDialog extends HookConsumerWidget {
  const NoActiveProfileDialog({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: const Text('Подписка не загрузилась'),
      content: const Text(
        'При первом запуске приложение само получает вашу подписку с нашего '
        'сервера, но связаться с ним не удалось.\n\n'
        'Проверьте интернет и нажмите «Повторить». Если не помогает — '
        'попробуйте другую сеть (Wi-Fi или мобильный интернет) либо загляните '
        'на наш сайт.',
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await UriUtils.tryLaunch(Uri.parse('https://ihgap.xyz'));
          },
          child: const Text('Наш сайт'),
        ),
        FilledButton(
          onPressed: () {
            ref.invalidate(subscriptionSyncProvider);
            context.pop();
          },
          child: const Text('Повторить'),
        ),
      ],
    );
  }
}
