import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/revenuecat/revenuecat_config.dart';
import '../../../core/revenuecat/subscription_sync.dart';
import '../../auth/presentation/auth_provider.dart';
import 'plans_screen.dart';

/// Gear+ 初月無料の日次プロンプト（1日1回・お試し未利用者のみ）。
class GearPlusTrialPrompt {
  GearPlusTrialPrompt._();

  static String _prefsKey(String userId) =>
      'gear_plus_trial_prompt_date_$userId';

  static String _todayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  static Future<bool> wasShownToday(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKey(userId)) == _todayString();
  }

  static Future<void> markShownToday(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey(userId), _todayString());
  }

  /// 条件を満たす場合にダイアログを表示。表示したら true。
  static Future<bool> maybeShow(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final user = ref.read(authNotifierProvider).value;
    if (user == null || !user.shouldPromptGearPlusTrial) return false;
    if (await wasShownToday(user.userId)) return false;

    await markShownToday(user.userId);
    if (!context.mounted) return false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        icon: const Icon(Icons.workspace_premium,
            color: AppColors.primary, size: 40),
        title: const Text('Gear+ を1ヶ月無料でお試し'),
        content: const Text(
          '初回限定！いいね無制限・すれ違い履歴7日間・愛車ガード無制限など、'
          'Gear+ の全機能を1ヶ月無料で体験できます。\n\n'
          '無料期間終了後は、解約しない限り月額¥500のプランに自動更新されます。'
          '解約はいつでも App Store から可能です。',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('あとで'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PlansScreen()),
              );
            },
            child: const Text('1ヶ月無料で試す'),
          ),
        ],
      ),
    );
    return true;
  }

  /// PlansScreen / GearPlusScreen から直接購入フローを開始。
  static Future<void> purchaseGearPlusTrial(
    BuildContext context,
    WidgetRef ref,
  ) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
    );

    try {
      final info = await RevenueCatConfig.purchaseSubscription(
        AppConstants.gearPlusProductId,
      );
      if (!context.mounted) return;
      Navigator.pop(context);

      if (info == null) return;

      final user = ref.read(authNotifierProvider).value;
      if (user != null) {
        await SubscriptionSync.applyPurchase(
          user.userId,
          info,
          productId: AppConstants.gearPlusProductId,
        );
        ref.invalidate(authNotifierProvider);
      }

      if (context.mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Row(
              children: [
                Icon(LucideIcons.zap, size: 24, color: AppColors.primary),
                SizedBox(width: 8),
                Text('Gear+ のお試しが始まりました！'),
              ],
            ),
            content: const Text(
              '1ヶ月間、Gear+ の全機能を無料でお使いいただけます。\n\n'
              '無料期間終了後は解約しない限り月額¥500に自動更新されます。',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('購入エラー: $e')),
        );
      }
    }
  }
}
