import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../core/constants/app_colors.dart';

/// いいね受信時のポップアップ：「あなたの車に興味を持った人がいます」
class LikeReceivedDialog {
  LikeReceivedDialog._();

  static Future<void> show(
    BuildContext context, {
    required VoidCallback onViewLikes,
  }) {
    return showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Row(
          children: [
            Icon(LucideIcons.heart, size: 22, color: AppColors.primary),
            SizedBox(width: 8),
            Expanded(child: Text('あなたの車に興味を持った人がいます')),
          ],
        ),
        content: const Text('いいねタブから確認して、気になったら「いいね返し」でマッチしましょう。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                const Text('あとで', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            onPressed: onViewLikes,
            child: const Text('見てみる'),
          ),
        ],
      ),
    );
  }
}
