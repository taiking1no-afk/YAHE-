import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/errors.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/revenuecat/subscription_sync.dart';
import '../../auth/presentation/auth_provider.dart';
import '../data/store_repository.dart';
import '../models/item_model.dart';
import 'plans_screen.dart';
import 'gear_r_insights_screen.dart';

final _storeRepoProvider =
    Provider<StoreRepository>((ref) => StoreRepository());

final myItemsProvider =
    FutureProvider.autoDispose<List<UserItemState>>((ref) async {
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
    final plan =
        user?.plan == 'pit_in' ? 'pit_in' : (user?.effectivePlan ?? 'free');
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
            _PlanBanner(
                plan: plan,
                onUpgrade: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const PlansScreen()),
                    )),
            if (isGearR) ...[
              const SizedBox(height: 12),
              _GearRReportBanner(
                  onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const GearRInsightsScreen()),
                      )),
            ],
            const SizedBox(height: 24),

            // ─── 所持アイテム
            const Text('所持アイテム',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                )),
            const SizedBox(height: 8),
            itemsAsync.when(
              loading: () => const Center(
                  child: CircularProgressIndicator(color: AppColors.primary)),
              error: (_, __) => const SizedBox.shrink(),
              data: (items) => _ItemInventory(items: items),
            ),
            const SizedBox(height: 24),

            // ─── スポット購入
            const Text('アイテム購入',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                )),
            const SizedBox(height: 4),
            const Text(
              'アプリを使いながらスポットで購入できます',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '💡 いいねボタンの隣の🔥ボタンから、渋！/激渋！を消費して'
                '特定の相手への「いいね」だけを目立たせて送れます。\n'
                '渋！と激渋！を両方所持している場合、激渋！が優先して使用されます。',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 11, height: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            ...ItemType.values.map((type) => _ShopItem(
                  type: type,
                  onBuy: user == null
                      ? null
                      : () =>
                          _showPurchaseDialog(context, ref, type, user.userId),
                )),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  void _showPurchaseDialog(
      BuildContext context, WidgetRef ref, ItemType type, String userId) {
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
            Text(type.description,
                style: const TextStyle(
                    color: AppColors.textSecondary, height: 1.5)),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.payments_outlined,
                    size: 18, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(type.priceLabel,
                    style: const TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              // Apple審査ガイドライン 2.3.10 対応: iOS向けバイナリに
              // Google Play等の他プラットフォーム名を含めない（無関係な情報のため）。
              '※ ${defaultTargetPlatform == TargetPlatform.android ? "Google Play" : "App Store"}で決済されます',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
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

  Future<void> _processPurchase(
      BuildContext context, WidgetRef ref, ItemType type, String userId) async {
    // ローディング表示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
    );

    try {
      // RevenueCat で consumable アイテムを購入
      final purchaseResult = await Purchases.purchaseProduct(
        type.productId,
        type: PurchaseType.inapp, // 消費型アイテム
      );
      final customerInfo = purchaseResult.customerInfo;

      // 購入トランザクションが存在すれば成功
      final purchased = customerInfo.nonSubscriptionTransactions
          .any((t) => t.productIdentifier == type.productId);

      if (!purchased) {
        if (context.mounted) Navigator.pop(context);
        _showError(context, 'purchase_failed', type);
        return;
      }

      // サーバー側で RevenueCat 検証 → アイテム付与（クライアント直書き禁止）
      final synced = await SubscriptionSync.applyPurchase(
        userId,
        customerInfo,
        productId: type.productId,
      );
      ref.invalidate(myItemsProvider);
      ref.invalidate(authNotifierProvider);

      if (context.mounted) {
        Navigator.pop(context); // ローディング閉じる
        if (synced) {
          _showSuccess(context, type);
        } else {
          // 決済自体は成立しているが、サーバー側への反映(付与)に失敗している。
          // ここで「購入完了」と表示すると、実際にはアイテムが付かないまま
          // ユーザーには成功したように見えてしまう。
          _showError(context, 'sync_failed', type);
        }
      }
    } on PlatformException catch (e) {
      if (context.mounted) Navigator.pop(context);
      _showError(context, PurchasesErrorHelper.getErrorCode(e).name, type);
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
          type == ItemType.gearPlus24h
              ? '${type.label}を購入しました！\nGear+機能が24時間有効です。'
              : '${type.label}を購入しました！\n\nストア画面の「所持アイテム」から使用できます。',
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
    if (code == 'sync_failed') {
      return '購入処理は完了しましたが、アイテムの反映に失敗しました。\n'
          'しばらくしてからアプリを再起動してください。改善しない場合はお問い合わせください。';
    }
    if (code.contains('network') || code.contains('Network')) {
      return 'ネットワークエラーが発生しました。\n通信状況を確認してください。';
    }
    if (code.contains('payment') || code.contains('Payment')) {
      return '決済に失敗しました。\nお支払い情報を確認してください。';
    }
    if (code.contains('not_configured') ||
        code.contains('productNotAvailable')) {
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
                    'インサイトアクティビティ',
                    style: TextStyle(
                      color: Color(0xFF6C63FF),
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'いつでも最新のアクセス状況を確認できます',
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
                  Text(label,
                      style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w800,
                          fontSize: 16)),
                  if (desc.isNotEmpty)
                    Text(desc,
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                ],
              ),
            ),
            if (plan == 'free')
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('アップグレード',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── 所持アイテム一覧 ─────────────────────────────────────
class _ItemInventory extends ConsumerStatefulWidget {
  final List<UserItemState> items;
  const _ItemInventory({required this.items});

  @override
  ConsumerState<_ItemInventory> createState() => _ItemInventoryState();
}

class _ItemInventoryState extends ConsumerState<_ItemInventory> {
  // 使用処理中のアイテム種別。連打による二重消費を防ぐガード。
  final Set<ItemType> _busy = {};

  Future<void> _use(ItemType type, String userId) async {
    if (_busy.contains(type)) return;
    setState(() => _busy.add(type));
    try {
      final repo = ref.read(_storeRepoProvider);
      final ok = type.isTimedItem
          ? await repo.activateTimedItem(userId, type)
          : await repo.consumeItem(userId, type);
      ref.invalidate(myItemsProvider);
      // gear_plus_24h等はサーバー側でpremium_override_planを書き換えるため、
      // 反映されるようauthも合わせて更新する（以前は再起動まで反映されなかった）。
      ref.invalidate(authNotifierProvider);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('アイテムの使用に失敗しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('アイテムの使用に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(type));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authNotifierProvider).value;

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      // 発動中は「残り○○」の行が追加で入るため、1.6だと縦が足りず
      // ボタンが数ピクセルはみ出していた（Overflowed）。
      childAspectRatio: 1.3,
      // 24時間ギア+は購入した瞬間にサーバー側で自動発動し、在庫として
      // 貯まることが無い（quantityが常に0のまま）ため、他のアイテムと
      // 同じ「使用する」ボタン付きカードで並べると実質押せないボタンに
      // なってしまう。このアイテムだけ所持アイテム一覧には出さない。
      children: ItemType.values
          .where((type) => type != ItemType.gearPlus24h)
          .map((type) {
        final state = widget.items.firstWhere(
          (i) => i.type == type,
          orElse: () => UserItemState(type: type, quantity: 0),
        );
        // 渋！/激渋！は「いいね」ボタンの隣の🔥ボタンからのみ使用可能にする
        // （特定の相手だけをブーストする方式に統一。ここでの一括自己ブーストは廃止）。
        final isSendOnlyItem =
            type == ItemType.shibu || type == ItemType.gekiShibu;
        final canUse = user != null &&
            !isSendOnlyItem &&
            (state.quantity > 0 || state.isActive) &&
            !_busy.contains(type);
        return _InventoryCard(
          state: state,
          onUse: canUse ? () => _use(type, user.userId) : null,
          sendOnlyHint: isSendOnlyItem,
        );
      }).toList(),
    );
  }
}

class _InventoryCard extends StatelessWidget {
  final UserItemState state;
  final VoidCallback? onUse;
  final bool sendOnlyHint;

  const _InventoryCard(
      {required this.state, this.onUse, this.sendOnlyHint = false});

  void _showSendOnlyExplanation(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        title: Row(
          children: [
            Text(state.type.emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
            Text(state.type.label),
          ],
        ),
        content: const Text(
          '使用はいいね横の🔥ボタンで使用できるよ！\n'
          'YAHE画面・プロフィール画面のいいねボタンの隣にある🔥ボタンから、'
          '特定の相手への「いいね」をブーストして送れます。',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('わかった'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 渋！/激渋！には「発動」の概念が無い（いいね送信時に都度1個消費するだけ）ため、
    // active_until が残っていても常に非アクティブ扱いにする。
    final isActive = sendOnlyHint ? false : state.isActive;
    final color = isActive ? AppColors.primary : AppColors.textMuted;

    return GestureDetector(
      onTap: sendOnlyHint ? () => _showSendOnlyExplanation(context) : null,
      child: Container(
        padding: const EdgeInsets.all(10),
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
                if (!sendOnlyHint &&
                    (state.type.isTimedItem || state.isBoostActive))
                  Text(
                    // 未発動時は常に「0」と表示していたため、実際は複数個
                    // 持っていても所持数が無いように見えていた。
                    state.isActive ? '発動中' : '${state.quantity}個',
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700),
                  )
                else
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: state.quantity > 0
                          ? AppColors.primary.withOpacity(0.1)
                          : AppColors.border.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${state.quantity}個',
                      style: TextStyle(
                        color: state.quantity > 0
                            ? AppColors.primary
                            : AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            Text(state.type.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            if (isActive)
              Text('残り ${state.remainingLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: AppColors.primary, fontSize: 11)),
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
                    style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else if (sendOnlyHint)
              const Text(
                '🔥いいね画面から使用',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600),
              ),
          ],
        ),
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
                Text(type.label,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    )),
                Text(type.description,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.4,
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
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
