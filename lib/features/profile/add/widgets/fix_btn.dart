import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class FixBtn extends ConsumerWidget {
  const FixBtn({
    super.key,
    required this.height,
    required this.title,
    required this.onTap,
    this.icon,
    this.faIcon,
  }) : assert(icon != null || faIcon != null, 'Provide icon or faIcon');

  final double height;
  final String title;
  final IconData? icon;
  final IconData? faIcon;
  final GestureTapCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isMobile = Breakpoint(context).isMobile();
    final color = theme.colorScheme.primary;
    final borderRadius = BorderRadius.circular(18);
    final iconSize = isMobile ? 32.0 : 40.0;

    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Container(
          alignment: Alignment.center,
          height: height,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (faIcon != null)
                FaIcon(faIcon, size: iconSize, color: color)
              else
                Icon(icon, size: iconSize, color: color),
              Gap(isMobile ? 4 : 8),
              Text(
                title,
                style: isMobile
                    ? theme.textTheme.titleSmall!.copyWith(color: color)
                    : theme.textTheme.titleMedium!.copyWith(color: color),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
