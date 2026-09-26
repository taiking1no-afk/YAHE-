import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

class YaheAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final List<Widget>? actions;
  final bool showBack;
  final PreferredSizeWidget? bottom;

  const YaheAppBar({
    super.key,
    this.title,
    this.actions,
    this.showBack = true,
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    final canPop = showBack && Navigator.canPop(context);

    return AppBar(
      automaticallyImplyLeading: false,
      leadingWidth: canPop ? 44 : 72,
      leading: canPop
          ? IconButton(
              icon: const Icon(Icons.arrow_back_ios,
                  size: 18, color: AppColors.textPrimary),
              onPressed: () => Navigator.pop(context),
            )
          : const Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(width: 14),
                Text(
                  'YAHE',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
      title: title != null
          ? Text(title!,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700))
          : null,
      actions: actions,
      bottom: bottom,
    );
  }

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));
}
