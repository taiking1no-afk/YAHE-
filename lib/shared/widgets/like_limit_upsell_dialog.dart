import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../features/settings/presentation/gear_plus_screen.dart';

/// 無料プランの1日いいね上限（10回）に達した際に表示する、Gear+加入への
/// 導線付きダイアログ。すれ違い経由（encounter）の場合は expiresAt を渡すと
/// 「このすれ違いは後◯時間で消えてしまいます」を併せて表示する。
class LikeLimitUpsellDialog {
  LikeLimitUpsellDialog._();

  static String? _remainingLabel(DateTime? expiresAt) {
    if (expiresAt == null) return null;
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) return null;
    final hours = remaining.inHours;
    final mins = remaining.inMinutes % 60;
    if (hours > 0) return '$hours時間$mins分';
    return '$mins分';
  }

  static Future<void> show(BuildContext context, {DateTime? expiresAt}) {
    final remainingLabel = _remainingLabel(expiresAt);
    return showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        title: const Text('本日のいいね上限に達しました'),
        content: Text(
          '無料プランのいいねは1日10回までです。\n\n'
          'せっかくすれ違えたのにもったいないです。'
          '${remainingLabel != null ? '\nこのすれ違いは後$remainingLabelで消えてしまいます。' : ''}'
          '\n\nGear+にしていいねを無制限で送ろう。',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GearPlusScreen()),
              );
            },
            child: const Text('Gear+を見る'),
          ),
        ],
      ),
    );
  }
}
