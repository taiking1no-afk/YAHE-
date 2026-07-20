import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

class YaheAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final List<Widget>? actions;
  final bool showBack;

  const YaheAppBar({
    super.key,
    this.title,
    this.actions,
    this.showBack = true,
  });

  @override
  Widget build(BuildContext context) {
    final canPop = showBack && Navigator.canPop(context);

    return AppBar(
      automaticallyImplyLeading: false,
      leadingWidth: canPop ? 96 : 72,
      leading: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 14),
          const Text(
            'YAHE',
            style: TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w900,
              fontSize: 15,
              letterSpacing: 1.5,
            ),
          ),
          if (canPop) ...[
            const SizedBox(width: 2),
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: const Icon(Icons.arrow_back_ios, size: 18, color: AppColors.textPrimary),
            ),
          ],
        ],
      ),
      title: title != null
          ? Text(title!, style: const TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w700))
          : null,
      actions: actions,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
