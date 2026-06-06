import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/features/app_trial/app_trial_controller.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Баннер статуса подписки на главном экране.
///
/// Читает результат [subscriptionSyncProvider] и показывает остаток дней
/// и кнопку действия по ситуации:
///  - не привязан → «Привязать Telegram» (deep-link в бота);
///  - привязан, истекла → «Оформить подписку» (оплата в боте);
///  - привязан, активна → срок + «Продлить».
/// После возврата из бота срабатывает ре-синк и баннер обновляется сам.
class SubscriptionBanner extends ConsumerWidget {
  const SubscriptionBanner({super.key});

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final result = ref.watch(subscriptionSyncProvider).valueOrNull;
    if (result == null) return const SizedBox.shrink();

    final linked = result.linked;
    final expired = result.status == 'expired';
    final expires = result.expiresAt;
    final daysLeft = expires != null ? (expires.difference(DateTime.now()).inHours / 24).ceil() : null;

    final String title;
    final String actionLabel;
    final String? actionUrl;
    final Color bg;

    if (!linked) {
      if (expired) {
        title = 'Пробный период закончился';
        bg = theme.colorScheme.errorContainer;
      } else {
        title = daysLeft != null ? 'Пробный период: ещё $daysLeft дн.' : 'Пробный период активен';
        bg = theme.colorScheme.primaryContainer;
      }
      actionLabel = 'Привязать Telegram';
      actionUrl = result.linkUrl;
    } else if (expired) {
      title = 'Подписка истекла';
      actionLabel = 'Оформить подписку';
      actionUrl = result.payUrl;
      bg = theme.colorScheme.errorContainer;
    } else {
      title = expires != null ? 'Подписка активна до ${_fmtDate(expires)}' : 'Подписка активна';
      actionLabel = 'Продлить';
      actionUrl = result.payUrl;
      bg = theme.colorScheme.primaryContainer;
    }

    final url = actionUrl;
    final hasAction = url != null && url.isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
          ),
          if (hasAction) ...[
            const Gap(8),
            FilledButton.tonal(
              onPressed: () => UriUtils.tryLaunch(Uri.parse(url)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(actionLabel),
            ),
          ],
        ],
      ),
    );
  }
}
