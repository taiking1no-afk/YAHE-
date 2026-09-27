import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:purchases_flutter/errors.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/revenuecat/revenuecat_config.dart';
import '../../../core/revenuecat/subscription_sync.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../legal/terms_screen.dart';

// プラン商品ID定数
const _kPitInId = 'yahe_pit_in_monthly';
const _kGearPlusId = 'yahe_gear_plus_monthly';
const _kGearRId = 'yahe_gear_r_monthly';

class PlansScreen extends ConsumerWidget {
  const PlansScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authNotifierProvider).value;
    final currentPlan = user?.effectivePlan ?? 'free';
    final paidPlan = user?.plan ?? 'free';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('プランを選ぶ')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (user != null && user.isOnTrial) ...[
              _TrialBanner(daysRemaining: user.trialDaysRemaining ?? 0),
              const SizedBox(height: 16),
            ] else if (user != null && user.isPremiumViaGrant) ...[
              _GrantBanner(source: user.premiumOverrideSource),
              const SizedBox(height: 16),
            ],
            const Text(
              '自分のスタイルに合ったプランで\nドライブをもっと楽しもう',
              style: TextStyle(
                  color: AppColors.textSecondary, fontSize: 14, height: 1.6),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),

            // ─── 無料プラン
            _PlanCard(
              name: '無料',
              price: '¥0',
              color: AppColors.textMuted,
              isCurrent: currentPlan == 'free' && paidPlan == 'free',
              features: const [
                (LucideIcons.check, 'すれ違い検知・通知'),
                (LucideIcons.check, 'いいね 10回/日'),
                (LucideIcons.check, 'すれ違い履歴 24時間'),
                (LucideIcons.check, '愛車ガード 3ヶ所'),
                (LucideIcons.check, '愛車登録 2台'),
              ],
              onSelect: null,
            ),
            const SizedBox(height: 12),

            // ─── ピットイン
            _PlanCard(
              name: 'ピットイン',
              price: '¥300/月',
              color: const Color(0xFFFF8C00),
              isCurrent: paidPlan == 'pit_in',
              badge: 'お得',
              features: const [
                (LucideIcons.zap, 'ニトロ 毎月1個配布'),
                (LucideIcons.flame, '渋！ 毎月10個配布'),
              ],
              note: currentPlan == 'gear_plus' || currentPlan == 'gear_r'
                  ? 'Gear+以上に加入中は不要です（同等以上のアイテムが毎月届きます）'
                  : '無料プランのまま毎月アイテムが届く補給プラン',
              // Gear+/Gear R加入中は同等以上のアイテムを別途受け取れるため、
              // ピットインを重ねて購入しても無駄な二重課金になるだけ（プランは
              // gear_plus/gear_rが優先され、pit_inには絶対に切り替わらない）。
              onSelect: paidPlan == 'pit_in' ||
                      currentPlan == 'gear_plus' ||
                      currentPlan == 'gear_r'
                  ? null
                  : () => _purchasePlan(context, ref, _kPitInId, 'ピットイン'),
            ),
            const SizedBox(height: 12),

            // ─── Gear+
            _PlanCard(
              name: 'Gear+',
              price: user != null && user.shouldPromptGearPlusTrial
                  ? '初月無料 → ¥500/月'
                  : '¥500/月',
              color: AppColors.primary,
              // 24hアイテムや管理者付与によるeffectivePlanではなく、実際の
              // サブスク状態(paidPlan)で判定する。effectivePlanで判定すると、
              // 一時的な付与中はずっと「加入中」表示になり購入導線が消えて
              // しまっていた（本来一番案内したい層から導線が消える不具合）。
              isCurrent: paidPlan == 'gear_plus',
              badge: user != null && user.shouldPromptGearPlusTrial
                  ? '初月無料'
                  : '人気',
              features: const [
                (LucideIcons.zap, 'いいね 無制限'),
                (LucideIcons.zap, 'すれ違い履歴 7日間'),
                (LucideIcons.zap, '愛車ガード 無制限'),
                (LucideIcons.zap, '愛車登録 無制限'),
                (LucideIcons.flame, 'ニトロ 毎月1個付き'),
                (LucideIcons.flame, '渋！ 毎月10個付き'),
              ],
              note: user != null && user.shouldPromptGearPlusTrial
                  ? '初回のみ1ヶ月無料。期間終了後は解約しない限り月額¥500に自動更新されます'
                  : '別途スポット購入でアイテム追加可',
              onSelect: paidPlan == 'gear_plus' || paidPlan == 'gear_r'
                  ? null
                  : () => _purchasePlan(context, ref, _kGearPlusId, 'Gear+'),
              ctaLabel: user != null && user.shouldPromptGearPlusTrial
                  ? '1ヶ月無料で試す'
                  : null,
            ),
            const SizedBox(height: 12),

            // ─── Gear R
            _PlanCard(
              name: 'Gear R',
              price: '¥3,000/月',
              color: const Color(0xFF6C63FF),
              isCurrent: paidPlan == 'gear_r',
              badge: 'ビジネス向け',
              features: const [
                (LucideIcons.zap, 'スーパーニトロ 毎月1個付き'),
                (LucideIcons.star, '激渋！ 毎月10個付き'),
                (LucideIcons.trophy, '認証バッジ（購入後すぐ設定可能）'),
                (LucideIcons.barChart3, 'インサイトアクティビティ（いつでも見られるアクセス解析）'),
                (LucideIcons.check, 'Gear+ の全機能を含む'),
              ],
              note: '認証バッジは自由にラベルを設定できます（例：インフルエンサー、ユーチューバー）',
              onSelect: paidPlan == 'gear_r'
                  ? null
                  : () => _showGearRDialog(context, ref),
            ),
            const SizedBox(height: 16),

            // ─── 24時間ギア＋の案内
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: const Row(
                children: [
                  Icon(LucideIcons.rocket, size: 20, color: AppColors.primary),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'まずは試してみたい方へ：',
                            style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w700),
                          ),
                          TextSpan(
                            text:
                                ' ストアから「24時間ギア＋」(¥300) を購入すると、Gear+の全機能を24時間だけ体験できます',
                            style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                                height: 1.5),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 購入を復元
            TextButton(
              onPressed: () => _restorePurchases(context, ref),
              child: const Text('購入を復元',
                  style: TextStyle(color: AppColors.textMuted)),
            ),
            const SizedBox(height: 8),
            const Text(
              '・いつでもキャンセル可能\n'
              '・解約後は無料プランに降格\n'
              '・Gear+ 初回加入時は1ヶ月無料（期間終了24時間前までに解約しない限り月額¥500に自動更新）\n'
              '・サブスクは期間終了24時間前までに解約しない限り自動更新されます\n'
              '・決済は App Store で管理されます',
              style: TextStyle(
                  color: AppColors.textMuted, fontSize: 11, height: 1.8),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            // App Store 要件：課金画面から規約・プライバシー・特商法へ導線を置く
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _LegalLinkButton(
                  label: '利用規約',
                  builder: (_) => const TermsScreen(),
                ),
                const Text('・',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
                _LegalLinkButton(
                  label: 'プライバシーポリシー',
                  builder: (_) => const PrivacyPolicyScreen(),
                ),
                const Text('・',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
                _LegalLinkButton(
                  label: '特定商取引法に基づく表記',
                  builder: (_) => const CommercialTransactionScreen(),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 比較表
            _CompareTable(currentPlan: currentPlan),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ─── Gear+ / Gear R 購入（共通）
  Future<void> _purchasePlan(
    BuildContext context,
    WidgetRef ref,
    String productId,
    String planName,
  ) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
    );

    try {
      final info = await RevenueCatConfig.purchaseSubscription(productId);
      if (!context.mounted) return;
      Navigator.pop(context); // ローディング閉じる

      if (info == null) return; // キャンセル

      // Supabase のプランを RevenueCat から同期
      final user = ref.read(authNotifierProvider).value;
      var synced = false;
      if (user != null) {
        synced = await SubscriptionSync.applyPurchase(
          user.userId,
          info,
          productId: productId,
        );
        ref.invalidate(authNotifierProvider);
      }

      if (context.mounted) {
        if (synced) {
          _showSuccessDialog(context, planName, productId == _kGearRId,
              isPitIn: productId == _kPitInId);
        } else {
          // 決済自体は成立しているが、サーバー側への反映に失敗している。
          // このまま「加入しました」と出すと、実際にはプランが切り替わって
          // いないのに成功したように見えてしまう。
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('決済は完了しましたが、反映に失敗しました。'
                  'しばらくしてからアプリを再起動してください。'),
              duration: Duration(seconds: 6),
            ),
          );
        }
      }
    } on PlatformException catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context);
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code != PurchasesErrorCode.purchaseCancelledError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('購入に失敗しました: ${code.name}')),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エラーが発生しました: $e')),
      );
    }
  }

  // Gear R の購入確認ダイアログ
  void _showGearRDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Row(
          children: [
            Icon(LucideIcons.zap, size: 24, color: Color(0xFF6C63FF)),
            SizedBox(width: 8),
            Text('Gear R へ加入'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '月額 ¥3,000 で加入します。',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16),
            ),
            SizedBox(height: 12),
            Text(
              '加入後、すべての機能がすぐに使えます：\n'
              '・スーパーニトロ 毎月1個\n'
              '・激渋！ 毎月10個\n'
              '・認証バッジ（自由にラベル設定可能）\n'
              '・インサイトアクティビティ（随時閲覧可能なアクセス解析）\n'
              '・Gear+ の全機能',
              style: TextStyle(
                  color: AppColors.textSecondary, fontSize: 13, height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF)),
            onPressed: () {
              Navigator.pop(context);
              _purchasePlan(context, ref, _kGearRId, 'Gear R');
            },
            child: const Text('¥3,000/月で加入する'),
          ),
        ],
      ),
    );
  }

  void _showSuccessDialog(BuildContext context, String planName, bool isGearR,
      {bool isPitIn = false}) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Row(
          children: [
            Icon(
                isPitIn
                    ? LucideIcons.flag
                    : isGearR
                        ? LucideIcons.zap
                        : LucideIcons.zap,
                size: 24,
                color: AppColors.primary),
            const SizedBox(width: 8),
            Text('$planName に加入しました！'),
          ],
        ),
        content: Text(
          isPitIn
              ? '加入ありがとうございます！\n\n毎月ニトロ1個＋渋！10個が届きます。'
              : isGearR
                  ? '加入ありがとうございます！\n\nすべての機能がすぐに使えます。\n\n認証バッジは「プロフィール編集」からラベルを設定できます。'
                  : '加入ありがとうございます！\nすべての機能が使えるようになりました。',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          ElevatedButton(
              onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _restorePurchases(BuildContext context, WidgetRef ref) async {
    try {
      final info = await RevenueCatConfig.restorePurchases();
      if (!context.mounted) return;

      // restorePurchases() はAPI呼び出し自体が成功する限り常にCustomerInfoを
      // 返す（何も購入していない新規ユーザーでも）。infoの有無ではなく、
      // 有効なエンタイトルメントが実際にあるかで判定しないと、復元対象が
      // 無くても常に「復元しました」と表示されてしまっていた。
      final hasActiveEntitlement =
          info != null && info.entitlements.active.isNotEmpty;
      if (!hasActiveEntitlement) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('復元できる購入が見つかりませんでした')),
        );
        return;
      }

      // 有効なエンタイトルメントを確認してプランを更新
      final user = ref.read(authNotifierProvider).value;
      var synced = false;
      if (user != null) {
        synced = await SubscriptionSync.applyPurchase(user.userId, info);
        ref.invalidate(authNotifierProvider);
      }
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(synced ? '購入を復元しました' : '復元に失敗しました。もう一度お試しください。')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('復元に失敗しました')),
      );
    }
  }
}

class _TrialBanner extends StatelessWidget {
  final int daysRemaining;
  const _TrialBanner({required this.daysRemaining});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.gift, size: 22, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Gear+ 無料体験中（残り${daysRemaining > 0 ? '$daysRemaining日' : '24時間以内'}）\n'
              '期間終了後は解約しない限り月額¥500に自動更新されます',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GrantBanner extends StatelessWidget {
  final String? source;
  const _GrantBanner({this.source});

  @override
  Widget build(BuildContext context) {
    final label = switch (source) {
      'influencer' => 'インフルエンサー特典',
      'test' => 'テストアカウント',
      _ => '特別付与',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF6C63FF).withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.35)),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.sparkles, size: 22, color: Color(0xFF6C63FF)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$labelでプレミアム機能を利用中',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String name;
  final String price;
  final Color color;
  final bool isCurrent;
  final String? badge;
  final List<(IconData, String)> features;
  final String? note;
  final VoidCallback? onSelect;
  final String? ctaLabel;

  const _PlanCard({
    required this.name,
    required this.price,
    required this.color,
    required this.isCurrent,
    this.badge,
    required this.features,
    this.note,
    this.onSelect,
    this.ctaLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCurrent ? color : AppColors.border,
          width: isCurrent ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(name,
                  style: TextStyle(
                      color: color, fontSize: 20, fontWeight: FontWeight.w900)),
              if (badge != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: color, borderRadius: BorderRadius.circular(8)),
                  child: Text(badge!,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700)),
                ),
              ],
              const Spacer(),
              if (isCurrent)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: color.withOpacity(0.3)),
                  ),
                  child: Text('利用中',
                      style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(price,
              style: TextStyle(
                  color: color, fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          ...features.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(f.$1, size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(f.$2,
                          style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                              height: 1.4)),
                    ),
                  ],
                ),
              )),
          if (note != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8)),
              child: Text(note!,
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 11, height: 1.5)),
            ),
          ],
          if (onSelect != null) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onSelect,
                style: ElevatedButton.styleFrom(backgroundColor: color),
                child: Text(ctaLabel ?? '$nameに加入する'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LegalLinkButton extends StatelessWidget {
  final String label;
  final WidgetBuilder builder;
  const _LegalLinkButton({required this.label, required this.builder});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: const Size(0, 0),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () =>
          Navigator.push(context, MaterialPageRoute(builder: builder)),
      child: Text(label,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
    );
  }
}

class _CompareTable extends StatelessWidget {
  final String currentPlan;
  const _CompareTable({required this.currentPlan});

  @override
  Widget build(BuildContext context) {
    // (機能名, 無料, ピットイン, Gear+, Gear R)
    const rows = [
      ('いいね/日', '10回', '10回', '無制限', '無制限'),
      ('すれ違い履歴', '24時間', '24時間', '7日間', '7日間'),
      ('愛車ガード', '3ヶ所', '3ヶ所', '無制限', '無制限'),
      ('愛車登録', '2台', '2台', '無制限', '無制限'),
      ('ニトロ', '購入のみ', '月1個', '月1個', '─'),
      ('渋！', '購入のみ', '月10個', '月10個', '─'),
      ('スーパーニトロ', '─', '─', '─', '月1個'),
      ('激渋！', '─', '─', '─', '月10個'),
      ('認証バッジ', '─', '─', '─', '◯'),
      ('インサイトアクティビティ', '─', '─', '─', '随時'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: const Row(
              children: [
                Expanded(flex: 3, child: SizedBox()),
                Expanded(
                    flex: 2,
                    child: Text('無料',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 10,
                            fontWeight: FontWeight.w700))),
                Expanded(
                    flex: 2,
                    child: Text('ピットイン',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Color(0xFFFF8C00),
                            fontSize: 10,
                            fontWeight: FontWeight.w700))),
                Expanded(
                    flex: 2,
                    child: Text('Gear+',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700))),
                Expanded(
                    flex: 2,
                    child: Text('Gear R',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Color(0xFF6C63FF),
                            fontSize: 10,
                            fontWeight: FontWeight.w700))),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                          flex: 3,
                          child: Text(row.$1,
                              style: const TextStyle(
                                  color: AppColors.textPrimary, fontSize: 11))),
                      Expanded(
                          flex: 2,
                          child: Text(row.$2,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 11))),
                      Expanded(
                          flex: 2,
                          child: Text(row.$3,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Color(0xFFFF8C00),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600))),
                      Expanded(
                          flex: 2,
                          child: Text(row.$4,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600))),
                      Expanded(
                          flex: 2,
                          child: Text(row.$5,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Color(0xFF6C63FF),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600))),
                    ],
                  ),
                ),
                if (i < rows.length - 1)
                  const Divider(height: 1, color: AppColors.border),
              ],
            );
          }),
        ],
      ),
    );
  }
}

// Supabase のインポート用 stub（実際は import が必要）
