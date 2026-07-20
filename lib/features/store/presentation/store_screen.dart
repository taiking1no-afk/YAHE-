import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../../../core/constants/app_colors.dart';
import '../../auth/presentation/auth_provider.dart';
import '../data/store_repository.dart';
import '../models/item_model.dart';
import 'plans_screen.dart';
import 'gear_r_report_screen.dart';

final _storeRepoProvider = Provider<StoreRepository>((ref) => StoreRepository());

final myItemsProvider = FutureProvider.autoDispose<List<UserItemState>>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return [];
  return ref.read(_storeRepoProvider).fetchMyItems(user.userId);
});

class StoreScreen extends ConsumerWidget {
  const StoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authNotifierProvider).value;
    final itemsAsync = ref.watch(myItemsProvider);
    // effectivePlan は premium 機能判定用のため pit_in を 'free' に丸めてしまう。
    // バナー表示だけは pit_in を区別する必要があるため個別に判定する。
    final plan = user?.plan == 'pit_in' ? 'pit_in' : (user?.effectivePlan ?? 'free');
    final isGearR = user?.isGearR ?? false;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('ストア')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── 現在のプラン
            _PlanBanner(plan: plan, onUpgrade: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PlansScreen()),
            )),
            if (isGearR) ...[
              const SizedBox(height: 12),
              _GearRReportBanner(onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GearRReportScreen()),
              )),
            ],
            const SizedBox(height: 24),

            // ─── 所持アイテム
            const Text('所持アイテム', style: TextStyle(
              color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: 8),
            itemsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator(color: AppColors.primary)),
              error: (_, __) => const SizedBox.shrink(),
              data: (items) => _ItemInventory(items: items),
            ),
            const SizedBox(height: 24),

            // ─── スポット購入
            const Text('アイテム購入', style: TextStyle(
              color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: 4),
            const Text(
              'アプリを使いながらスポットで購入できます',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            ...ItemType.values.map((type) => _ShopItem(
              type: type,
              onBuy: user == null ? null : () => _showPurchaseDialog(context, ref, type, user.userId),
            )),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  void _showPurchaseDialog(BuildContext context, WidgetRef ref, ItemType type, String userId) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Row(
          children: [
            Text(type.emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 8),
            Text(type.label),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(type.description, style: const TextStyle(color: AppColors.textSecondary, height: 1.5)),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.payments_outlined, size: 18, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(type.priceLabel,
                    style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '※ App Store / Google Playで決済されます',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _processPurchase(context, ref, type, userId);
            },
            child: Text('${type.priceLabel}で購入'),
          ),
        ],
      ),
    );
  }

  Future<void> _processPurchase(BuildContext context, WidgetRef ref, ItemType type, String userId) async {
    // ローディング表示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator(color: AppColors.primary)),
    );

    try {
      // RevenueCat で consumable アイテムを購入
      final customerInfo = await Purchases.purchaseProduct(
        type.productId,
        type: PurchaseType.inapp, // 消費型アイテム
      );

      // 購入トランザクションが存在すれば成功
      final purchased = customerInfo.nonSubscriptionTransactions
          .any((t) => t.productIdentifier == type.productId);

      if (!purchased) {
        if (context.mounted) Navigator.pop(context);
        _showError(context, 'purchase_failed', type);
        return;
      }

      // Supabase にアイテムを付与
      final repo = ref.read(_storeRepoProvider);
      if (type == ItemType.gearPlus24h) {
        // 24時間ギア＋は購入即発動
        await repo.activateTimedItem(userId, type);
      } else {
        final count = type.isTimedItem ? 1 : 10;
        await repo.addItems(userId, type, count);
      }
      await repo.recordPurchase(userId, type.productId, type.priceJpy);
      ref.invalidate(myItemsProvider);
      ref.invalidate(authNotifierProvider);

      if (context.mounted) {
        Navigator.pop(context); // ローディング閉じる
        _showSuccess(context, type);
      }
    } on PurchasesErrorCode catch (e) {
      if (context.mounted) Navigator.pop(context);
      _showError(context, e.name, type);
    } catch (e) {
      if (context.mounted) Navigator.pop(context);
      _showError(context, e.toString(), type);
    }
  }

  void _showSuccess(BuildContext context, ItemType type) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Row(
          children: [
            Text(type.emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 8),
            const Text('購入完了'),
          ],
        ),
        content: Text(
          '${type.label}を購入しました！\n\nストア画面の「所持アイテム」から使用できます。',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showError(BuildContext context, String code, ItemType type) {
    // キャンセルは無視
    if (code == PurchasesErrorCode.purchaseCancelledError.name) return;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('購入エラー'),
        content: Text(
          _errorMessage(code),
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  String _errorMessage(String code) {
    if (code.contains('network') || code.contains('Network')) {
      return 'ネットワークエラーが発生しました。\n通信状況を確認してください。';
    }
    if (code.contains('payment') || code.contains('Payment')) {
      return '決済に失敗しました。\nお支払い情報を確認してください。';
    }
    if (code.contains('not_configured') || code.contains('productNotAvailable')) {
      return 'このアイテムは現在購入できません。\n（RevenueCatの設定が必要です）';
    }
    return '購入処理中にエラーが発生しました。\nもう一度お試しください。';
  }
}

class _GearRReportBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _GearRReportBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF6C63FF).withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.35)),
        ),
        child: const Row(
          children: [
            Text('📊', style: TextStyle(fontSize: 22)),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '月次アクセスレポート',
                    style: TextStyle(
                      color: Color(0xFF6C63FF),
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '毎月1日に前月分をプッシュでお届け',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Color(0xFF6C63FF)),
          ],
        ),
      ),
    );
  }
}

// ─── 現在のプランバナー ────────────────────────────────────
class _PlanBanner extends StatelessWidget {
  final String plan;
  final VoidCallback onUpgrade;

  const _PlanBanner({required this.plan, required this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    final (label, color, desc) = switch (plan) {
      'gear_r' => ('Gear R', const Color(0xFF6C63FF), 'インフルエンサー・企業向けプラン'),
      'gear_plus' => ('Gear+', AppColors.primary, 'プレミアムプラン加入中'),
      'pit_in' => ('ピットイン', const Color(0xFFFF8C00), '毎月ニトロ1個＋渋！10個をお届け'),
      _ => ('無料プラン', AppColors.textMuted, ''),
    };

    return GestureDetector(
      onTap: plan != 'gear_r' ? onUpgrade : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withOpacity(0.15), color.withOpacity(0.05)],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.4), width: 1.5),
        ),
        child: Row(
          children: [
            Icon(Icons.workspace_premium, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 16)),
                  if (desc.isNotEmpty)
                    Text(desc, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                ],
              ),
            ),
            if (plan == 'free')
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('アップグレード', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── 所持アイテム一覧 ─────────────────────────────────────
class _ItemInventory extends ConsumerWidget {
  final List<UserItemState> items;
  const _ItemInventory({required this.items});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authNotifierProvider).value;

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 1.6,
      children: ItemType.values.map((type) {
        final state = items.firstWhere(
          (i) => i.type == type,
          orElse: () => UserItemState(type: type, quantity: 0),
        );
        return _InventoryCard(
          state: state,
          onUse: user == null || (state.quantity <= 0 && !state.isActive)
              ? null
              : () async {
                  final repo = ref.read(_storeRepoProvider);
                  if (type.isTimedItem) {
                    await repo.activateTimedItem(user.userId, type);
                  } else {
                    await repo.consumeItem(user.userId, type);
                  }
                  ref.invalidate(myItemsProvider);
                },
        );
      }).toList(),
    );
  }
}

class _InventoryCard extends StatelessWidget {
  final UserItemState state;
  final VoidCallback? onUse;

  const _InventoryCard({required this.state, this.onUse});

  @override
  Widget build(BuildContext context) {
    final isActive = state.isActive;
    final color = isActive ? AppColors.primary : AppColors.textMuted;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? AppColors.primary : AppColors.border,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(state.type.emoji, style: const TextStyle(fontSize: 18)),
              const Spacer(),
              if (state.type.isTimedItem)
                Text(
                  isActive ? '発動中' : '0',
                  style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: state.quantity > 0 ? AppColors.primary.withOpacity(0.1) : AppColors.border.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${state.quantity}個',
                    style: TextStyle(
                      color: state.quantity > 0 ? AppColors.primary : AppColors.textMuted,
                      fontSize: 12, fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          Text(state.type.label, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
          if (isActive)
            Text('残り ${state.remainingLabel}', style: const TextStyle(color: AppColors.primary, fontSize: 11)),
          const Spacer(),
          if (onUse != null)
            GestureDetector(
              onTap: onUse,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '使用する',
                  style: TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── ショップアイテム ─────────────────────────────────────
class _ShopItem extends StatelessWidget {
  final ItemType type;
  final VoidCallback? onBuy;

  const _ShopItem({required this.type, this.onBuy});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Text(type.emoji, style: const TextStyle(fontSize: 28)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type.label, style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700,
                )),
                Text(type.description, style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12, height: 1.4,
                )),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onBuy,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                type.priceLabel,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
