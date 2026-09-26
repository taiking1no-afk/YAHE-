import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

/// 「マッチしました！」ポップアップ。
/// home_screen.dart / likes_screen.dart にそれぞれ重複実装されていたものを統合。
class MatchCelebrationDialog {
  MatchCelebrationDialog._();

  static Future<void> show(
    BuildContext context, {
    required VoidCallback onShare,
    required VoidCallback onViewMatch,
  }) {
    return showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Row(
          children: [
            Icon(Icons.favorite, color: AppColors.primary),
            SizedBox(width: 8),
            Text('マッチしました！'),
          ],
        ),
        content: const Text('相互いいね成立！\nマッチタブから詳細を見てみましょう。'),
        actions: [
          TextButton.icon(
            onPressed: onShare,
            icon: const Icon(Icons.ios_share, size: 18),
            label: const Text('SNSでシェア'),
          ),
          ElevatedButton(
            onPressed: onViewMatch,
            child: const Text('マッチを見る'),
          ),
        ],
      ),
    );
  }
}
