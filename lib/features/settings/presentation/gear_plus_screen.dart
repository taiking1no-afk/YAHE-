import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/revenuecat/revenuecat_config.dart';
import '../../../core/revenuecat/subscription_sync.dart';
import '../../../features/auth/presentation/auth_provider.dart';
import '../../../shared/widgets/yahe_app_bar.dart';

class GearPlusScreen extends ConsumerStatefulWidget {
  const GearPlusScreen({super.key});

  @override
  ConsumerState<GearPlusScreen> createState() => _GearPlusScreenState();
}

class _GearPlusScreenState extends ConsumerState<GearPlusScreen> {
  bool _loading = false;

  Future<void> _purchase() async {
    final wasIntroEligible =
        ref.read(authNotifierProvider).value?.shouldPromptGearPlusTrial ?? false;
    setState(() => _loading = true);
    try {
      final info = await RevenueCatConfig.purchaseSubscription(
        AppConstants.gearPlusProductId,
      );
      if (info == null) {
        return;
      }

      final isActive = info.entitlements.active.containsKey('gear_plus') ||
          info.entitlements.active.containsKey('gear_r');

      if (!isActive) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('購入の確認ができませんでした。しばらくしてから再度お試しください。')),
          );
        }
        return;
      }

      final user = ref.read(authNotifierProvider).value;
      if (user != null) {
        await SubscriptionSync.applyPurchase(user.userId, info);
        await ref.read(authNotifierProvider.notifier).build();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              wasIntroEligible
                  ? 'Gear+ の1ヶ月無料お試しが始まりました！'
                  : 'Gear+ の加入が完了しました！',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('購入エラー: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restore() async {
    setState(() => _loading = true);
    try {
      final info = await RevenueCatConfig.restorePurchases();
      final active = info?.entitlements.active.containsKey('gear_plus') ?? false;

      if (active) {
        final user = ref.read(authNotifierProvider).value;
        if (user != null && info != null) {
          await SubscriptionSync.applyPurchase(user.userId, info);
          await ref.read(authNotifierProvider.notifier).build();
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(active ? '購入を復元しました！' : '復元できる購入が見つかりませんでした')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('復元エラー: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authNotifierProvider).value;
    final isPremium = user?.isPremium ?? false;
    final showIntroOffer = user?.shouldPromptGearPlusTrial ?? false;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const YaheAppBar(title: 'Gear+'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.primary,
                    AppColors.primaryDark,
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  const Icon(Icons.workspace_premium, color: Colors.white, size: 48),
                  const SizedBox(height: 12),
                  const Text(
                    'Gear+',
                    style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 2),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isPremium
                        ? (user?.isOnTrial == true ? '無料体験中' : '加入中')
                        : (showIntroOffer ? '初月無料 → 月額 ¥500' : '月額 ¥500'),
                    style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 16),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            _CompareTable(),
            const SizedBox(height: 28),

            if (!isPremium) ...[
              if (showIntroOffer) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primary.withOpacity(0.3)),
                  ),
                  child: const Text(
                    '🎁 初回限定 1ヶ月無料\n'
                    '無料期間終了後は解約しない限り月額¥500に自動更新されます',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      height: 1.6,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _purchase,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(showIntroOffer
                          ? '1ヶ月無料で試す'
                          : 'Gear+ に加入する  ¥500/月'),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _loading ? null : _restore,
                child: const Text('購入を復元', style: TextStyle(color: AppColors.textMuted)),
              ),
              const SizedBox(height: 16),
              Text(
                showIntroOffer
                    ? '・初回のみ1ヶ月無料\n・無料期間終了後は解約しない限り月額¥500に自動更新\n・いつでもキャンセル可能\n・決済はApp Storeで管理されます'
                    : '・いつでもキャンセル可能\n・解約後は無料プランに降格\n・決済はApp Storeで管理されます',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.8),
                textAlign: TextAlign.center,
              ),
            ] else
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.success.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.success.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle_outline, color: AppColors.success),
                    const SizedBox(width: 8),
                    Text(
                      user?.isOnTrial == true
                          ? 'Gear+ 無料体験中です'
                          : 'Gear+ 加入中です',
                      style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CompareTable extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final rows = [
      ('1日のいいね数', '10回まで', '無制限'),
      ('すれ違い履歴保持', '24時間', '7日間'),
      ('愛車ガードゾーン数', '3個まで', '無制限'),
      ('登録できる愛車台数', '2台まで', '無制限'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: const Row(
              children: [
                Expanded(flex: 3, child: SizedBox()),
                Expanded(
                  flex: 2,
                  child: Text('無料', textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                ),
                Expanded(
                  flex: 2,
                  child: Text('Gear+', textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          ...rows.asMap().entries.map((e) {
            final i = e.key;
            final row = e.value;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          row.$1,
                          style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          row.$2,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          row.$3,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (i < rows.length - 1) const Divider(height: 1, color: AppColors.border),
              ],
            );
          }),
        ],
      ),
    );
  }
}
